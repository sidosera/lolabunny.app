# bundle.cmake - Build Lolabunny.app from Swift binary.

set(APP_BUNDLE "${BUNDLE_DIR}/${APP_NAME}.app")
set(CONTENTS_DIR "${APP_BUNDLE}/Contents")
set(MACOS_DIR "${CONTENTS_DIR}/MacOS")
set(RESOURCES_DIR "${CONTENTS_DIR}/Resources")
set(INFO_PLIST "${APP_PACKAGE_DIR}/Info.plist")

if(NOT EXISTS "${INFO_PLIST}")
    message(FATAL_ERROR "Info.plist not found: ${INFO_PLIST}")
endif()
if(NOT EXISTS "${ENTITLEMENTS}")
    message(FATAL_ERROR "Entitlements file not found: ${ENTITLEMENTS}")
endif()
if(NOT EXISTS "${ICON_SOURCE}")
    message(FATAL_ERROR "Icon source not found: ${ICON_SOURCE}")
endif()

file(REMOVE_RECURSE "${BUNDLE_DIR}")
file(MAKE_DIRECTORY "${MACOS_DIR}" "${RESOURCES_DIR}")

execute_process(
    COMMAND "${SWIFT_EXECUTABLE}" build
        --package-path "${APP_PACKAGE_DIR}"
        --scratch-path "${SWIFT_SCRATCH_PATH}"
        --configuration release
        --show-bin-path
        --triple "${SWIFT_TRIPLE}"
    OUTPUT_VARIABLE SWIFT_BIN_DIR
    OUTPUT_STRIP_TRAILING_WHITESPACE
    COMMAND_ERROR_IS_FATAL ANY
)

set(SWIFT_BIN "${SWIFT_BIN_DIR}/${APP_NAME}")
if(NOT EXISTS "${SWIFT_BIN}")
    message(FATAL_ERROR "Swift binary not found: ${SWIFT_BIN}")
endif()

execute_process(
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "${SWIFT_BIN}" "${MACOS_DIR}/${APP_NAME}"
    COMMAND_ERROR_IS_FATAL ANY
)

execute_process(COMMAND "${STRIP_EXECUTABLE}" "${MACOS_DIR}/${APP_NAME}" COMMAND_ERROR_IS_FATAL ANY)

execute_process(
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "${INFO_PLIST}" "${CONTENTS_DIR}/Info.plist"
    COMMAND_ERROR_IS_FATAL ANY
)
file(WRITE "${CONTENTS_DIR}/PkgInfo" "APPL????")

if(EXISTS "${SOURCE_DIR}/.version")
    execute_process(
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "${SOURCE_DIR}/.version" "${RESOURCES_DIR}/.version"
        COMMAND_ERROR_IS_FATAL ANY
    )
else()
    file(WRITE "${RESOURCES_DIR}/.version" "dev")
endif()

execute_process(
    COMMAND "${SIPS_EXECUTABLE}" -z 18 18 "${ICON_SOURCE}" --out "${RESOURCES_DIR}/bunny.png"
    OUTPUT_QUIET
    ERROR_QUIET
    COMMAND_ERROR_IS_FATAL ANY
)
execute_process(
    COMMAND "${SIPS_EXECUTABLE}" -z 36 36 "${ICON_SOURCE}" --out "${RESOURCES_DIR}/bunny@2x.png"
    OUTPUT_QUIET
    ERROR_QUIET
    COMMAND_ERROR_IS_FATAL ANY
)

set(ICONSET_DIR "${RESOURCES_DIR}/AppIcon.iconset")
file(MAKE_DIRECTORY "${ICONSET_DIR}")

set(ICON_SPECS
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)

foreach(icon_spec IN LISTS ICON_SPECS)
    string(REPLACE ":" ";" icon_parts "${icon_spec}")
    list(GET icon_parts 0 icon_size)
    list(GET icon_parts 1 icon_name)
    execute_process(
        COMMAND "${SIPS_EXECUTABLE}" -z "${icon_size}" "${icon_size}" "${ICON_SOURCE}" --out "${ICONSET_DIR}/${icon_name}"
        OUTPUT_QUIET
        ERROR_QUIET
        COMMAND_ERROR_IS_FATAL ANY
    )
endforeach()

execute_process(
    COMMAND "${ICONUTIL_EXECUTABLE}" --convert icns "${ICONSET_DIR}" --output "${RESOURCES_DIR}/AppIcon.icns"
    COMMAND_ERROR_IS_FATAL ANY
)
file(REMOVE_RECURSE "${ICONSET_DIR}")

message(STATUS "Signing with identity: ${CODESIGN_IDENTITY}")
execute_process(
    COMMAND "${CODESIGN_EXECUTABLE}" --force --deep
        --sign "${CODESIGN_IDENTITY}"
        --entitlements "${ENTITLEMENTS}"
        "${APP_BUNDLE}"
    COMMAND_ERROR_IS_FATAL ANY
)

message(STATUS "Bundle ready: ${APP_BUNDLE}")
