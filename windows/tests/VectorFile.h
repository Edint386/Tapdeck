// Reads the reference vectors in windows/vectors.
//
// A .tdv file is a list of named arrays, all little-endian:
//
//     "TDV1"                       magic
//     u32 count                    number of entries
//     per entry:
//       u32 length, bytes          the name, UTF-8
//       u8 type                    1 f32, 2 f64, 3 i32, 4 UTF-8 text
//       u32 count                  elements (bytes for text)
//       data
//
// windows/tools/vectors writes them from the Swift code; see its main.swift.

#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace tapdeck::test {

class VectorFile {
public:
    /// Throws std::runtime_error when the file is missing or malformed.
    static VectorFile load(const std::string& path);

    bool has(const std::string& name) const;
    const std::vector<float>& f32(const std::string& name) const;
    const std::vector<double>& f64(const std::string& name) const;
    const std::vector<std::int32_t>& i32(const std::string& name) const;
    const std::string& text(const std::string& name) const;

    /// A single value, for entries that hold one.
    double number(const std::string& name) const;

private:
    std::map<std::string, std::vector<float>> f32_;
    std::map<std::string, std::vector<double>> f64_;
    std::map<std::string, std::vector<std::int32_t>> i32_;
    std::map<std::string, std::string> text_;
};

} // namespace tapdeck::test
