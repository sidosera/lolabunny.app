include(FetchContent)

find_program(APP_CARGO_EXECUTABLE NAMES cargo REQUIRED)

if(NOT DEFINED Rust_CARGO_TARGET)
    message("Rust: Rust_CARGO_TARGET is not defined")
endif()

if(NOT DEFINED CARGO_TARGET_DIR OR "${CARGO_TARGET_DIR}" STREQUAL "")
    set(CARGO_TARGET_DIR "${CMAKE_BINARY_DIR}/cargo")
endif()

set(Rust_CARGO_TARGET_DIR "${CARGO_TARGET_DIR}")

FetchContent_Declare(
    Corrosion
    GIT_REPOSITORY https://github.com/corrosion-rs/corrosion.git
    GIT_TAG v0.5
)
FetchContent_MakeAvailable(Corrosion)

corrosion_import_crate(
    MANIFEST_PATH "${CMAKE_CURRENT_SOURCE_DIR}/Cargo.toml"
    CRATES "${LOLABUNNY_SERVER_BIN}"
    PROFILE release
)

add_custom_target(app-server.build DEPENDS "${LOLABUNNY_SERVER_BIN}")

add_custom_target(app-server.clean
    COMMAND "${CMAKE_COMMAND}" -E env "CARGO_TARGET_DIR=${CARGO_TARGET_DIR}" "${APP_CARGO_EXECUTABLE}" clean
        --manifest-path "${CMAKE_CURRENT_SOURCE_DIR}/Cargo.toml"
    WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}"
    VERBATIM
)

if(BUILD_TESTING)
    add_test(
        NAME test.app-server
        COMMAND "${CMAKE_COMMAND}" -E env "CARGO_TARGET_DIR=${CARGO_TARGET_DIR}" "${APP_CARGO_EXECUTABLE}" test
            --manifest-path "${CMAKE_CURRENT_SOURCE_DIR}/Cargo.toml"
    )
    set_tests_properties(test.app-server PROPERTIES
        WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}"
        LABELS "app-server"
    )
endif()
