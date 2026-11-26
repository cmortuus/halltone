// Replying from the address a datagram was sent to. A Mac on Ethernet and Wi-Fi at once has two
// addresses on the same subnet; a plain sendto() picks the source by route (usually Ethernet),
// so a phone that talks to the Wi-Fi address gets replies from the other one and its connected
// socket drops them. The Swift overlay lacks the CMSG macros, hence C.
#ifdef __APPLE__
#define __APPLE_USE_RFC_3542 1
#else
// Glibc hides in6_pktinfo / in_pktinfo and struct msghdr extensions without this.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif
#endif
#include "CHalltone.h"
#include <string.h>
#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <sys/uio.h>

// The SDK exposes these only with __APPLE_USE_RFC_3542 set before the system headers, which a
// precompiled Darwin module ignores. Darwin's RFC 3542 values (Linux defines both itself):
#ifdef __APPLE__
#ifndef IPV6_RECVPKTINFO
#define IPV6_RECVPKTINFO 61
#endif
#ifndef IPV6_PKTINFO
#define IPV6_PKTINFO 46
#endif
#endif // __APPLE__

// Darwin sockaddrs carry their length; Linux derives it from the family.
static socklen_t es_sockaddr_len(const struct sockaddr_storage *a) {
#ifdef __APPLE__
    return a->ss_len;
#else
    switch (a->ss_family) {
        case AF_INET: return sizeof(struct sockaddr_in);
        case AF_INET6: return sizeof(struct sockaddr_in6);
        default: return sizeof *a;
    }
#endif
}

int es_udp_enable_pktinfo(int fd) {
    int on = 1;
    int r = setsockopt(fd, IPPROTO_IPV6, IPV6_RECVPKTINFO, &on, sizeof on);
#ifndef __APPLE__
    // Linux reports the local address of IPv4 datagrams on a dual-stack socket through the
    // IPv4 option (IP_PKTINFO), not IPV6_PKTINFO. Best effort: a v6-only socket rejects it.
    (void)setsockopt(fd, IPPROTO_IP, IP_PKTINFO, &on, sizeof on);
#endif
    return r;
}

long es_udp_recv(int fd, void *buf, size_t cap, struct sockaddr_storage *from, uint8_t local[16], int *has_local) {
    char cbuf[128];
    struct iovec iov = { buf, cap };
    struct msghdr m;
    memset(&m, 0, sizeof m);
    m.msg_name = from; m.msg_namelen = sizeof *from;
    m.msg_iov = &iov; m.msg_iovlen = 1;
    m.msg_control = cbuf; m.msg_controllen = sizeof cbuf;
    *has_local = 0;
    ssize_t n = recvmsg(fd, &m, 0);
    if (n < 0) return n;
    for (struct cmsghdr *h = CMSG_FIRSTHDR(&m); h; h = CMSG_NXTHDR(&m, h)) {
        if (h->cmsg_level == IPPROTO_IPV6 && h->cmsg_type == IPV6_PKTINFO) {
            struct in6_pktinfo pi;
            memcpy(&pi, CMSG_DATA(h), sizeof pi);
            memcpy(local, &pi.ipi6_addr, 16);
            *has_local = 1;
        }
#ifndef __APPLE__
        else if (h->cmsg_level == IPPROTO_IP && h->cmsg_type == IP_PKTINFO) {
            // IPv4 datagram on a dual-stack socket: report the local address as ::ffff:a.b.c.d.
            struct in_pktinfo p4;
            memcpy(&p4, CMSG_DATA(h), sizeof p4);
            memset(local, 0, 10);
            local[10] = 0xff; local[11] = 0xff;
            memcpy(local + 12, &p4.ipi_spec_dst, 4);
            *has_local = 1;
        }
#endif
    }
    return n;
}

long es_udp_send_from(int fd, const void *buf, size_t len, const struct sockaddr_storage *to, const uint8_t local[16]) {
    struct iovec iov = { (void *)buf, len };
    struct msghdr m;
    memset(&m, 0, sizeof m);
    m.msg_name = (void *)to; m.msg_namelen = es_sockaddr_len(to);
    m.msg_iov = &iov; m.msg_iovlen = 1;
    // Sized for the larger of the two.
    char cbuf[CMSG_SPACE(sizeof(struct in6_pktinfo))];
    if (local) {
        memset(cbuf, 0, sizeof cbuf);
        m.msg_control = cbuf;
        struct cmsghdr *h = (struct cmsghdr *)cbuf;
        struct in6_addr a;
        memcpy(&a, local, 16);
        if (IN6_IS_ADDR_V4MAPPED(&a)) {
            // IPv4 peer on the dual-stack socket: IPV6_PKTINFO is ignored for mapped addresses,
            // but the IPv4 option is honoured.
            struct in_pktinfo p4;
            memset(&p4, 0, sizeof p4);
            memcpy(&p4.ipi_spec_dst, &a.s6_addr[12], 4);
            h->cmsg_level = IPPROTO_IP; h->cmsg_type = IP_PKTINFO;
            h->cmsg_len = CMSG_LEN(sizeof p4);
            memcpy(CMSG_DATA(h), &p4, sizeof p4);
            m.msg_controllen = CMSG_SPACE(sizeof p4);
        } else {
            struct in6_pktinfo p6;
            memset(&p6, 0, sizeof p6);
            p6.ipi6_addr = a;
            h->cmsg_level = IPPROTO_IPV6; h->cmsg_type = IPV6_PKTINFO;
            h->cmsg_len = CMSG_LEN(sizeof p6);
            memcpy(CMSG_DATA(h), &p6, sizeof p6);
            m.msg_controllen = CMSG_SPACE(sizeof p6);
        }
    }
    ssize_t n = sendmsg(fd, &m, 0);
    if (n < 0 && local && (errno == EADDRNOTAVAIL || errno == EINVAL)) {
        // That address went away (cable pulled): let the route choose.
        m.msg_control = NULL; m.msg_controllen = 0;
        n = sendmsg(fd, &m, 0);
    }
    return n;
}
