# OpenVPNNext - Native CMake
# 编译: NAPI bridge + OpenVPN core (arm64-v8a) + 链接 OpenSSL

cmake_minimum_required(VERSION 3.5.0)
project(OpenVPNNext)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

# ---------------- OpenVPN core 源文件清单 ----------------
# 用 GLOB 自动收集，避免手写遗漏。排除不可用/平台无关文件：
#   - win32*.c wfp_block.c: Windows 专属
#   - dco_*.c: 数据通道卸载(仅 Linux/Windows/FreeBSD 内核)
#   - crypto_mbedtls*.c ssl_mbedtls*.c ssl_verify_mbedtls*.c pkcs11_mbedtls.c: mbedTLS 后端(未启用)
#   - console_systemd.c: systemd 专属
#   - lzo.c: LZO 压缩(禁用)
#   - networking_freebsd.c networking_iproute2.c: 其他平台网络
file(GLOB OPENVPN_CORE_SRC
    core/compat/*.c
    core/openvpn/*.c
)
list(FILTER OPENVPN_CORE_SRC EXCLUDE REGEX ".*(win32|wfp_block|dco_|crypto_mbedtls|ssl_mbedtls|ssl_verify_mbedtls|pkcs11_mbedtls|console_systemd|lzo|networking_freebsd|networking_iproute2)\\.c$")

# ---------------- 头文件与宏 ----------------
include_directories(
    ${NATIVERENDER_ROOT_PATH}
    ${NATIVERENDER_ROOT_PATH}/include
    ${NATIVERENDER_ROOT_PATH}/core
    ${NATIVERENDER_ROOT_PATH}/core/include
    ${NATIVERENDER_ROOT_PATH}/core/compat
    ${NATIVERENDER_ROOT_PATH}/core/build-ohos
    ${NATIVERENDER_ROOT_PATH}/libs/include
)

# 复用 CMake 交叉编译生成的 config.h（含 TARGET_ANDROID、ENABLE_MANAGEMENT 等）
add_definitions(-DHAVE_CONFIG_H)

# 与上游 CMakeLists 一致：DNS updown 脚本路径宏（OpenVPN 客户端实际不用，给编译通过）
add_definitions(-DDEFAULT_DNS_UPDOWN="\\\"/system/bin/dns-updown\\\"")
# 插件目录宏（客户端不用插件，给编译通过）
add_definitions(-DPLUGIN_LIBDIR="\\\"/system/lib/openvpn/plugins\\\"")

# ---------------- 链接 OpenSSL 静态库 ----------------
set(OPENSSL_LIBS
    ${NATIVERENDER_ROOT_PATH}/libs/arm64-v8a/libcrypto.a
    ${NATIVERENDER_ROOT_PATH}/libs/arm64-v8a/libssl.a
)

# ---------------- 编译目标: libentry.so ----------------
add_library(entry SHARED
    napi_init.cpp
    openvpn_bridge.c
    management_client.c
    ${OPENVPN_CORE_SRC}
)
target_link_libraries(entry PUBLIC libace_napi.z.so libhilog_ndk.z.so libnet_connection.so ${OPENSSL_LIBS} z)
