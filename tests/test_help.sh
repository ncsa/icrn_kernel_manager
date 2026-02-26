#!/bin/bash

# Test file for help and basic command functionality

source "$(dirname "$0")/test_common.sh"

test_help_command() {
    setup_test_env
    set_test_env
    local output
    output=$("$ICRN_MANAGER" help 2>&1 </dev/null)
    
    # Check if help shows usage information
    if echo "$output" | grep -q "usage:" && \
       echo "$output" | grep -q "kernels"; then
        return 0
    else
        echo "Help output: $output"
        return 1
    fi
}

test_invalid_command() {
    setup_test_env
    set_test_env
    local output
    output=$("$ICRN_MANAGER" invalid_command 2>&1 </dev/null)
    
    # Check if it fails with appropriate error message
    if echo "$output" | grep -q "Function.*not recognized" || \
       echo "$output" | grep -q "usage:"; then
        return 0
    else
        echo "Invalid command output: $output"
        return 1
    fi
}

test_kernels_help() {
    setup_test_env
    set_test_env
    local output
    # kernels (no subcommand) triggers check_and_init_if_needed -> kernels__init which prompts; pipe "y"
    output=$(printf 'y\n' | "$ICRN_MANAGER" kernels 2>&1)
    
    # Check if it shows error for missing subcommand
    if echo "$output" | grep -q "Error: No subcommand specified" || \
       echo "$output" | grep -q "usage:"; then
        return 0
    else
        echo "Kernels help output: $output"
        return 1
    fi
}

# Run tests when sourced or executed directly
run_test "help_command" test_help_command "Help command shows usage information"
run_test "invalid_command" test_invalid_command "Invalid command fails gracefully"
run_test "kernels_help" test_kernels_help "Kernels command without subcommand shows help" 