cmake_minimum_required(VERSION 3.20)
project(Lolabunny LANGUAGES NONE)

if(NOT APPLE)
    message(FATAL_ERROR "Lolabunny supports macOS builds only.")
endif()

set(LOLABUNNY_APP_NAME "Lolabunny")
set(LOLABUNNY_SERVER_BIN "lolabunny")
set(LOLABUNNY_MIN_MACOS "12.0")

set(SWIFT_SCRATCH_PATH "${CMAKE_BINARY_DIR}/swiftpm" CACHE PATH "SwiftPM scratch directory")
set(CODESIGN_IDENTITY "-" CACHE STRING "Codesign identity ('-' for ad-hoc)")

include("${CMAKE_SOURCE_DIR}/cmake/arch.cmake")
arch_detect_for_plugins("${LOLABUNNY_MIN_MACOS}")

include(CTest)
add_subdirectory(app)
add_subdirectory(app-server)

add_custom_target(build ALL DEPENDS app.build app-server.build)
add_custom_target(bundle DEPENDS app.bundle)
add_custom_target(dmg DEPENDS app.dmg)
add_custom_target(install-app DEPENDS app.install)
add_custom_target(run DEPENDS app.run)

add_custom_target(build-rust DEPENDS app-server.build)
add_custom_target(build-swift DEPENDS app.build)

add_custom_target(clean-all DEPENDS app.clean app-server.clean)
