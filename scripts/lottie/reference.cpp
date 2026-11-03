// Renders frames of a Lottie file with rlottie, Telegram's renderer, as the reference for the app's renderer.
// Writes <out>/<frame>.pam (RGBA, not premultiplied), which ImageMagick reads.
//
//   reference <file.json> <out dir> <size> <frame>...
//
// Built by scripts/lottie-compare.py against third-party/rlottie-telegram (Telegram's fork).

#include <rlottie.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

int main(int argc, char **argv)
{
    if (argc < 5) {
        fprintf(stderr, "usage: %s <file.json> <out dir> <size> <frame>...\n", argv[0]);
        return 2;
    }
    std::ifstream file(argv[1]);
    std::stringstream json;
    json << file.rdbuf();
    auto animation = rlottie::Animation::loadFromData(json.str(), argv[1], "", false);
    if (!animation) {
        fprintf(stderr, "rlottie could not load %s\n", argv[1]);
        return 1;
    }
    size_t size = std::stoul(argv[3]);
    std::vector<uint32_t> buffer(size * size);
    for (int i = 4; i < argc; i++) {
        size_t frame = std::stoul(argv[i]);
        std::fill(buffer.begin(), buffer.end(), 0);
        rlottie::Surface surface(buffer.data(), size, size, size * 4);
        animation->renderSync(frame, surface);
        std::string path = std::string(argv[2]) + "/" + argv[i] + ".pam";
        FILE *out = fopen(path.c_str(), "wb");
        fprintf(out, "P7\nWIDTH %zu\nHEIGHT %zu\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n", size, size);
        for (uint32_t pixel : buffer) {
            uint8_t a = pixel >> 24, r = pixel >> 16, g = pixel >> 8, b = pixel;
            if (a > 0 && a < 255) {
                r = uint8_t(std::min(255, r * 255 / a));
                g = uint8_t(std::min(255, g * 255 / a));
                b = uint8_t(std::min(255, b * 255 / a));
            }
            uint8_t rgba[4] = {r, g, b, a};
            fwrite(rgba, 1, 4, out);
        }
        fclose(out);
    }
    printf("%zu frames\n", animation->totalFrame());
    return 0;
}
