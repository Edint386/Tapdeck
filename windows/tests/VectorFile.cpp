#include "VectorFile.h"

#include <cstring>
#include <fstream>
#include <iterator>
#include <stdexcept>

namespace tapdeck::test {

namespace {

class Reader {
public:
    Reader(std::vector<unsigned char> bytes, std::string path) : bytes_(std::move(bytes)), path_(std::move(path)) {}

    template <typename T>
    T value() {
        need(sizeof(T));
        T result;
        std::memcpy(&result, bytes_.data() + offset_, sizeof(T)); // the platforms are little-endian
        offset_ += sizeof(T);
        return result;
    }

    template <typename T>
    std::vector<T> array(std::uint32_t count) {
        need(static_cast<std::size_t>(count) * sizeof(T));
        std::vector<T> result(count);
        if (count > 0) std::memcpy(result.data(), bytes_.data() + offset_, count * sizeof(T));
        offset_ += count * sizeof(T);
        return result;
    }

    std::string text(std::uint32_t count) {
        need(count);
        std::string result(reinterpret_cast<const char*>(bytes_.data() + offset_), count);
        offset_ += count;
        return result;
    }

    bool atEnd() const { return offset_ == bytes_.size(); }

private:
    void need(std::size_t size) const {
        if (bytes_.size() - offset_ < size) throw std::runtime_error(path_ + ": truncated");
    }

    std::vector<unsigned char> bytes_;
    std::string path_;
    std::size_t offset_ = 0;
};

template <typename Map>
const typename Map::mapped_type& find(const Map& map, const std::string& name, const char* type) {
    const auto found = map.find(name);
    if (found == map.end()) throw std::runtime_error("no " + std::string(type) + " entry named " + name);
    return found->second;
}

} // namespace

VectorFile VectorFile::load(const std::string& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) throw std::runtime_error(path + ": cannot open");
    std::vector<unsigned char> bytes((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
    Reader reader(std::move(bytes), path);

    if (reader.text(4) != "TDV1") throw std::runtime_error(path + ": not a TDV1 file");
    VectorFile file;
    const auto entries = reader.value<std::uint32_t>();
    for (std::uint32_t entry = 0; entry < entries; ++entry) {
        const auto name = reader.text(reader.value<std::uint32_t>());
        const auto type = reader.value<std::uint8_t>();
        const auto count = reader.value<std::uint32_t>();
        switch (type) {
        case 1: file.f32_[name] = reader.array<float>(count); break;
        case 2: file.f64_[name] = reader.array<double>(count); break;
        case 3: file.i32_[name] = reader.array<std::int32_t>(count); break;
        case 4: file.text_[name] = reader.text(count); break;
        default: throw std::runtime_error(path + ": unknown type in entry " + name);
        }
    }
    if (!reader.atEnd()) throw std::runtime_error(path + ": trailing bytes");
    return file;
}

bool VectorFile::has(const std::string& name) const {
    return f32_.count(name) || f64_.count(name) || i32_.count(name) || text_.count(name);
}

const std::vector<float>& VectorFile::f32(const std::string& name) const { return find(f32_, name, "f32"); }
const std::vector<double>& VectorFile::f64(const std::string& name) const { return find(f64_, name, "f64"); }
const std::vector<std::int32_t>& VectorFile::i32(const std::string& name) const { return find(i32_, name, "i32"); }
const std::string& VectorFile::text(const std::string& name) const { return find(text_, name, "text"); }

double VectorFile::number(const std::string& name) const {
    if (f64_.count(name) && f64_.at(name).size() == 1) return f64_.at(name)[0];
    if (f32_.count(name) && f32_.at(name).size() == 1) return f32_.at(name)[0];
    if (i32_.count(name) && i32_.at(name).size() == 1) return i32_.at(name)[0];
    throw std::runtime_error("no single number named " + name);
}

} // namespace tapdeck::test
