include_guard(GLOBAL)

function(arch_detect_for_plugins min_macos_version)
    if(NOT min_macos_version)
        message(FATAL_ERROR "arch_detect_for_plugins requires a macOS minimum version")
    endif()

    string(TOLOWER "${CMAKE_HOST_SYSTEM_PROCESSOR}" _host_arch)

    if(_host_arch MATCHES "^(arm64|aarch64)$")
        set(_arch_host "arm64")
        set(_rust_triple "aarch64-apple-darwin")
        set(_swift_arch "arm64")
    elseif(_host_arch MATCHES "^(x86_64|amd64)$")
        set(_arch_host "x86_64")
        set(_rust_triple "x86_64-apple-darwin")
        set(_swift_arch "x86_64")
    else()
        message(FATAL_ERROR "Unsupported host architecture: ${CMAKE_HOST_SYSTEM_PROCESSOR}")
    endif()

    # Generic architecture constants.
    set(ARCH_HOST "${_arch_host}" PARENT_SCOPE)
    set(ARCH_RUST_TRIPLE "${_rust_triple}" PARENT_SCOPE)
    set(ARCH_SWIFT_ARCH "${_swift_arch}" PARENT_SCOPE)
    set(
        ARCH_SWIFT_TRIPLE
        "${_swift_arch}-apple-macos${min_macos_version}"
        PARENT_SCOPE
    )
    
    # Toolchain architecture constants
    # ------------------------------------ 

    # Rust
    set(Rust_CARGO_TARGET "${_rust_triple}" PARENT_SCOPE)

    # Swift
    set(SWIFTPM_TARGET_TRIPLE "${_swift_arch}-apple-macos${min_macos_version}" PARENT_SCOPE)

    # ------------------------------------
endfunction()
