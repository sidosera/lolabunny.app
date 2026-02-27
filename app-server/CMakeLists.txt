include(FetchContent)

find_program(APP_CARGO_EXECUTABLE NAMES cargo REQUIRED)

if(NOT DEFINED Rust_CARGO_TARGET)
    message("Rust: Rust_CARGO_TARGET is not defined")
endif()

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
    COMMAND "${APP_CARGO_EXECUTABLE}" clean
        --manifest-path "${CMAKE_CURRENT_SOURCE_DIR}/Cargo.toml"
    WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}"
    VERBATIM
)

if(BUILD_TESTING)
    add_test(
        NAME test.app-server
        COMMAND "${APP_CARGO_EXECUTABLE}" test
            --manifest-path "${CMAKE_CURRENT_SOURCE_DIR}/Cargo.toml"
    )
    set_tests_properties(test.app-server PROPERTIES
        WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}"
        LABELS "app-server"
    )
endif()
