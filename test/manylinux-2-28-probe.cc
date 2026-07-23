#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

int main()
{
    const std::vector<std::string> components = { "manylinux", "2.28" };

    try {
        throw std::runtime_error(components.at(0) + " " + components.at(1));
    } catch (const std::runtime_error &error) {
        if (std::string(error.what()) != "manylinux 2.28") {
            return 1;
        }
    }

    std::cout << "c++ probe passed\n";
    return 0;
}
