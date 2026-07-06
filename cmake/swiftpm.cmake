include_guard(GLOBAL)
include(CMakeParseArguments)

option(SWIFTPM_DISABLE_SANDBOX "Pass --disable-sandbox to SwiftPM invocations." OFF)

function(_swiftpm_require prefix key)
    if(NOT DEFINED ${prefix}_${key} OR "${${prefix}_${key}}" STREQUAL "")
        message(FATAL_ERROR "swiftpm helper: missing required argument '${key}'")
    endif()
endfunction()

function(_swiftpm_sandbox_args output_variable)
    if(SWIFTPM_DISABLE_SANDBOX)
        set("${output_variable}" "--disable-sandbox" PARENT_SCOPE)
    else()
        set("${output_variable}" "" PARENT_SCOPE)
    endif()
endfunction()

function(swiftpm_add_build_target)
    set(options)
    set(one_value_args
        TARGET_NAME
        SWIFT_EXECUTABLE
        PACKAGE_PATH
        SCRATCH_PATH
        PRODUCT
        TRIPLE
        WORKING_DIRECTORY
        CONFIGURATION
    )
    cmake_parse_arguments(SWIFTPM "${options}" "${one_value_args}" "" ${ARGN})

    foreach(key IN ITEMS TARGET_NAME PACKAGE_PATH SCRATCH_PATH PRODUCT TRIPLE WORKING_DIRECTORY)
        _swiftpm_require("SWIFTPM" "${key}")
    endforeach()

    if(NOT SWIFTPM_SWIFT_EXECUTABLE)
        find_program(SWIFTPM_SWIFT_EXECUTABLE NAMES swift REQUIRED)
    endif()

    if(NOT SWIFTPM_CONFIGURATION)
        set(SWIFTPM_CONFIGURATION "release")
    endif()

    _swiftpm_sandbox_args(SWIFTPM_SANDBOX_ARGS)

    add_custom_target("${SWIFTPM_TARGET_NAME}"
        COMMAND "${SWIFTPM_SWIFT_EXECUTABLE}" build
            ${SWIFTPM_SANDBOX_ARGS}
            --package-path "${SWIFTPM_PACKAGE_PATH}"
            --scratch-path "${SWIFTPM_SCRATCH_PATH}"
            --configuration "${SWIFTPM_CONFIGURATION}"
            --product "${SWIFTPM_PRODUCT}"
            --triple "${SWIFTPM_TRIPLE}"
        WORKING_DIRECTORY "${SWIFTPM_WORKING_DIRECTORY}"
        VERBATIM
    )
endfunction()

function(swiftpm_add_test)
    set(options)
    set(one_value_args
        TEST_NAME
        SWIFT_EXECUTABLE
        PACKAGE_PATH
        SCRATCH_PATH
        WORKING_DIRECTORY
        LABEL
    )
    cmake_parse_arguments(SWIFTPMTEST "${options}" "${one_value_args}" "" ${ARGN})

    foreach(key IN ITEMS TEST_NAME PACKAGE_PATH SCRATCH_PATH WORKING_DIRECTORY LABEL)
        _swiftpm_require("SWIFTPMTEST" "${key}")
    endforeach()

    if(NOT SWIFTPMTEST_SWIFT_EXECUTABLE)
        find_program(SWIFTPMTEST_SWIFT_EXECUTABLE NAMES swift REQUIRED)
    endif()

    _swiftpm_sandbox_args(SWIFTPMTEST_SANDBOX_ARGS)

    add_test(
        NAME "${SWIFTPMTEST_TEST_NAME}"
        COMMAND "${SWIFTPMTEST_SWIFT_EXECUTABLE}" test
            ${SWIFTPMTEST_SANDBOX_ARGS}
            --package-path "${SWIFTPMTEST_PACKAGE_PATH}"
            --scratch-path "${SWIFTPMTEST_SCRATCH_PATH}"
    )
    set_tests_properties("${SWIFTPMTEST_TEST_NAME}" PROPERTIES
        WORKING_DIRECTORY "${SWIFTPMTEST_WORKING_DIRECTORY}"
        LABELS "${SWIFTPMTEST_LABEL}"
    )
endfunction()
