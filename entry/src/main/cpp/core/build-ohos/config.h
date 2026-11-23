
/* Configuration settings */
#define CONFIGURE_DEFINES "N/A"

/* Enable async push */
#define ENABLE_ASYNC_PUSH

/* Use mbed TLS library */
/* #undef ENABLE_CRYPTO_MBEDTLS */

/* Use Openssl */
#define ENABLE_CRYPTO_OPENSSL

/* Use wolfSSL crypto library */
/* #undef ENABLE_CRYPTO_WOLFSSL */

/* Enable shared data channel offload */
/* #undef ENABLE_DCO */

/* Enable debugging support (needed for verb>=4) */
#define ENABLE_DEBUG 1

/* Enable internal fragmentation support */
#define ENABLE_FRAGMENT 1

/* Enable linux data channel offload */
/* #undef ENABLE_LINUXDCO */

/* Enable LZ4 compression library */
/* #undef ENABLE_LZ4 */

/* Enable LZO compression library */
/* #undef ENABLE_LZO */

/* Enable dns-updown script hook */
/* #undef ENABLE_DNS_UPDOWN */

/* Enable NTLMv2 proxy support */
#define ENABLE_NTLM 1

/* Enable management server capability */
#define ENABLE_MANAGEMENT 1

/* Enable OFB and CFB cipher modes */
#define ENABLE_OFB_CFB_MODE

/* Enable PKCS11 */
/* #undef ENABLE_PKCS11 */

/* Enable plug-in support */
#define ENABLE_PLUGIN 1

/* Enable TCP Server port sharing */
#define ENABLE_PORT_SHARE

/* SELinux support */
/* #undef ENABLE_SELINUX */

/* enable sitnl support */
#define ENABLE_SITNL

/* Enable systemd integration */
/* #undef ENABLE_SYSTEMD */

/* Define to 1 if you have the <arpa/inet.h> header file. */
#define HAVE_ARPA_INET_H 1

/* Define to 1 if you have the `basename' function. */
#define HAVE_BASENAME

/* Define to 1 if you have the `chdir' function. */
#define HAVE_CHDIR

/* Define to 1 if you have the `chroot' function. */
#define HAVE_CHROOT

/* Define to 1 if you have the `chsize' function. */
/* #undef HAVE_CHSIZE */

/* struct cmsghdr needed for extended socket error support */
#define HAVE_CMSGHDR

/* git version information in config-version.h */
#define HAVE_CONFIG_VERSION_H

/* cmocka version information available in cmocka_version.h (>= 2.0.0) */
/* #undef HAVE_CMOCKA_VERSION_H */

/* Define to 1 if you have the `daemon' function. */
#define HAVE_DAEMON

/* Define to 1 if you have the <direct.h> header file. */
/* #undef HAVE_DIRECT_H */

/* Define to 1 if you have the `dirname' function. */
#define HAVE_DIRNAME

/* Define to 1 if you have the <dlfcn.h> header file. */
#define HAVE_DLFCN_H

/* Define to 1 if you have the <dmalloc.h> header file. */
/* #undef HAVE_DMALLOC_H */

/* Define to 1 if you have the `dup' function. */
#define HAVE_DUP

/* Define to 1 if you have the `dup2' function. */
#define HAVE_DUP2

/* Define to 1 if you have the `epoll_create' function. */
#define HAVE_EPOLL_CREATE

/* Define to 1 if you have the <err.h> header file. */
#define HAVE_ERR_H

/* Define to 1 if you have the <fcntl.h> header file. */
#define HAVE_FCNTL_H

/* Define to 1 if you have the `fork' function. */
#define HAVE_FORK
#define HAVE_EXECVE

/* Define to 1 if you have the `ftruncate' function. */
#define HAVE_FTRUNCATE

/* Define to 1 if you have the `getgrnam' function. */
#define HAVE_GETGRNAM

/* Define to 1 if you have the `getpeereid' function. */
/* #undef HAVE_GETPEEREID */

/* Define to 1 if you have the `getpwnam' function. */
#define HAVE_GETPWNAM

/* Define to 1 if you have the `getrlimit' function. */
#define HAVE_GETRLIMIT

/* Define to 1 if you have the `getsockname' function. */
#define HAVE_GETSOCKNAME

/* Define to 1 if you have the `gettimeofday' function. */
#define HAVE_GETTIMEOFDAY

/* Define to 1 if you have the <grp.h> header file. */
#define HAVE_GRP_H

/* struct in_pktinfo needed for IP_PKTINFO support */
#define HAVE_IN_PKTINFO

/* Define to 1 if you have the <io.h> header file. */
/* #undef HAVE_IO_H */

/* struct in_pktinfo.ipi_spec_dst needed for IP_PKTINFO support */
#define HAVE_IPI_SPEC_DST

/* Define to 1 if you have the <libgen.h> header file. */
#define HAVE_LIBGEN_H

/* Define to 1 if you have the <limits.h> header file. */
#define HAVE_LIMITS_H 1

/* Define to 1 if you have the <lzo1x.h> header file. */
#define HAVE_LZO1X_H 1

/* Define to 1 if you have the `mlockall' function. */
#define HAVE_MLOCKALL

/* struct msghdr needed for extended socket error support */
#define HAVE_MSGHDR

/* Define to 1 if you have the <netdb.h> header file. */
#define HAVE_NETDB_H

/* Define to 1 if you have the <netinet/in.h> header file. */
#define HAVE_NETINET_IN_H

/* Define to 1 if you have the <netinet/ip.h> header file. */
#define HAVE_NETINET_IP_H

/* Define to 1 if you have the <netinet/tcp.h> header file. */
#undef HAVE_NETINET_TCP_H

/* Define to 1 if you have the <net/if.h> header file. */
#define HAVE_NET_IF_H

/* Define to 1 if you have the <net/if_tun.h> header file. */
/* #undef HAVE_NET_IF_TUN_H */

/* Define to 1 if you have the <net/tun/if_tun.h> header file. */
/* #undef HAVE_NET_TUN_IF_TUN_H */

/* Define to 1 if you have the `nice' function. */
#define HAVE_NICE

/* Define to 1 if you have the `openlog' function. */
#define HAVE_OPENLOG

/* OpenSSL engine support available */
#undef HAVE_OPENSSL_ENGINE

/* Define to 1 if you have the `poll' function. */
#undef HAVE_POLL

/* Define to 1 if you have the <poll.h> header file. */
#define HAVE_POLL_H

/* Define to 1 if you have the `putenv' function. */
#undef HAVE_PUTENV

/* Define to 1 if you have the <pwd.h> header file. */
#define HAVE_PWD_H


/* Define to 1 if you have the `recvmsg' function. */
#define HAVE_RECVMSG
#define HAVE_SENDMSG

/* Define to 1 if you have the <resolv.h> header file. */
#define HAVE_RESOLV_H

/* sa_family_t, needed to hold AF_* info */
#define HAVE_SA_FAMILY_T

/* Define to 1 if you have the `sd_booted' function. */
#undef HAVE_SD_BOOTED

/* Define to 1 if you have the `setgid' function. */
#define HAVE_SETGID

/* Define to 1 if you have the `setgroups' function. */
#undef HAVE_SETGROUPS

/* Define to 1 if you have the `setsid' function. */
#define HAVE_SETSID

/* Define to 1 if you have the `setsockopt' function. */
#define HAVE_SETSOCKOPT 1

/* Define to 1 if you have the `setuid' function. */
#define HAVE_SETUID

/* Define to 1 if you have the <signal.h> header file. */
#define HAVE_SIGNAL_H 1

/* Define to 1 if you have the `socket' function. */
#undef HAVE_SOCKET

/* struct sock_extended_err needed for extended socket error support */
#undef HAVE_SOCK_EXTENDED_ERR

/* Define to 1 if you have the `stat' function. */
#define HAVE_STAT 1

/* Define to 1 if you have the <stdarg.h> header file. */
#define HAVE_STDARG_H 1

/* Define to 1 if you have the <stdint.h> header file. */
#define HAVE_STDINT_H 1

/* Define to 1 if you have the <stdio.h> header file. */
#define HAVE_STDIO_H 1

/* Define to 1 if you have the <stdlib.h> header file. */
#define HAVE_STDLIB_H 1

/* Define to 1 if you have the `strdup' function. */
#undef HAVE_STRDUP

/* Define to 1 if you have the <strings.h> header file. */
#define HAVE_STRINGS_H 1

/* Define to 1 if you have the <string.h> header file. */
#define HAVE_STRING_H 1

/* Define to 1 if you have the `strsep' function. */
#undef HAVE_STRSEP

/* Define to 1 if you have the `syslog' function. */
#define HAVE_SYSLOG

/* Define to 1 if you have the <syslog.h> header file. */
#define HAVE_SYSLOG_H

/* Define to 1 if you have the <sys/epoll.h> header file. */
#define HAVE_SYS_EPOLL_H

/* Define to 1 if you have the <sys/file.h> header file. */
#define HAVE_SYS_FILE_H 1

/* Define to 1 if you have the <sys/inotify.h> header file. */
#define HAVE_SYS_INOTIFY_H

/* Define to 1 if you have the <sys/ioctl.h> header file. */
#define HAVE_SYS_IOCTL_H

/* Define to 1 if you have the <sys/kern_control.h> header file. */
#undef HAVE_SYS_KERN_CONTROL_H

/* Define to 1 if you have the <sys/mman.h> header file. */
#define HAVE_SYS_MMAN_H

/* Define to 1 if you have the <sys/socket.h> header file. */
#define HAVE_SYS_SOCKET_H

/* Define to 1 if you have the <sys/sockio.h> header file. */
/* #undef HAVE_SYS_SOCKIO_H */

/* Define to 1 if you have the <sys/stat.h> header file. */
#define HAVE_SYS_STAT_H 1

/* Define to 1 if you have the <sys/time.h> header file. */
#define HAVE_SYS_TIME_H

/* Define to 1 if you have the <sys/types.h> header file. */
#define HAVE_SYS_TYPES_H 1

/* Define to 1 if you have the <sys/uio.h> header file. */
#define HAVE_SYS_UIO_H

/* Define to 1 if you have the <sys/un.h> header file. */
#define HAVE_SYS_UN_H

/* Define to 1 if you have the <sys/wait.h> header file. */
#define HAVE_SYS_WAIT_H

/* Define to 1 if you have the <tap-windows.h> header file. */
#undef HAVE_TAP_WINDOWS_H

/* Define to 1 if you have the <uapi.h> header file. */
#undef HAVE_UAPI_H

/* Define to 1 if you have the <unistd.h> header file. */
#define HAVE_UNISTD_H

/* Define to 1 if you have the <valgrind/memcheck.h> header file. */
#undef HAVE_VALGRIND_MEMCHECK_H

/* Availability of different mbed TLS features and APIs */
/* #undef HAVE_PSA_CRYPTO_H */

/* Path to ifconfig tool */
#define IFCONFIG_PATH "IFCONFIG_PATH-NOTFOUND"

/* Path to iproute tool */
#define IPROUTE_PATH "IPROUTE_PATH-NOTFOUND"

/* Path to route tool */
#define ROUTE_PATH "C:/Windows/System32/ROUTE.EXE"

/* OpenVPN version in Windows resource format - string */
#define OPENVPN_VERSION_RESOURCE 2,7,6,0

/* Name of package */
#define PACKAGE "openvpn"

/* Define to the address where bug reports for this package should be sent. */
#undef PACKAGE_BUGREPORT

/* Define to the full name of this package. */
#define PACKAGE_NAME "OpenVPN"

/* Define to the full name and version of this package. */
#define PACKAGE_STRING "OpenVPN 2.7.6"

/* Define to the version of this package. */
#define PACKAGE_VERSION "2.7.6"

/* Path to systemd-ask-password tool */
#undef SYSTEMD_ASK_PASSWORD_PATH

/* The tap-windows id */
#define TAP_WIN_COMPONENT_ID "tap0901"

/* The tap-windows version number is required for OpenVPN */
#define TAP_WIN_MIN_MAJOR 9

/* The tap-windows version number is required for OpenVPN */
#define TAP_WIN_MIN_MINOR 9

/* Are we running on Mac OS X? */
/* #undef TARGET_DARWIN */

/* Are we running on FreeBSD? */
/* #undef TARGET_FREEBSD */

/* Are we running on Linux? */
/* #undef TARGET_LINUX */

/* Are we running on Solaris/OpenIndiana? */
/* #undef TARGET_SOLARIS */

/* Are we running WIN32? */
/* #undef TARGET_WIN32 */

/* Are we targeting Android? */
#define TARGET_ANDROID

#define TARGET_ALIAS "OHOS"

/* Enable GNU extensions on systems that have them.  */
#ifndef _GNU_SOURCE
# define _GNU_SOURCE 1
#endif
