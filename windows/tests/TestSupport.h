// Reporting for the offline tests, in the same format as tapproof's.

#pragma once

#include <cstdarg>
#include <cstdio>
#include <string>

namespace tapdeck::test {

/// A label padded or cut to `width` characters, as Swift's
/// `padding(toLength:withPad:startingAt:)` does for the macOS tests.
inline std::string padded(const std::string& label, std::size_t width) {
    if (label.size() >= width) return label.substr(0, width);
    return label + std::string(width - label.size(), ' ');
}

inline std::string format(const char* pattern, ...) {
    char buffer[512];
    va_list arguments;
    va_start(arguments, pattern);
    std::vsnprintf(buffer, sizeof buffer, pattern, arguments);
    va_end(arguments);
    return buffer;
}

/// Counts results and prints one line per check: "PASS  label  detail".
class Report {
public:
    explicit Report(std::size_t labelWidth) : labelWidth_(labelWidth) {}

    void operator()(const std::string& label, bool ok, const std::string& detail = "") {
        total_ += 1;
        if (ok) passed_ += 1;
        std::printf("%s  %s %s\n", ok ? "PASS" : "FAIL", padded(label, labelWidth_).c_str(), detail.c_str());
    }

    /// Print the summary and return the process exit code.
    int finish() const {
        std::printf("%d/%d passed\n", passed_, total_);
        return passed_ == total_ ? 0 : 1;
    }

private:
    std::size_t labelWidth_;
    int passed_ = 0;
    int total_ = 0;
};

} // namespace tapdeck::test
