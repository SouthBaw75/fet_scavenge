# Builds every example into build/. Requires macOS with Xcode command line
# tools (xcode-select --install). No other dependencies.

CXX        := clang++
CXXFLAGS   := -std=c++20 -O2 -Wall -fobjc-arc
FRAMEWORKS := -framework Cocoa -framework Metal -framework MetalKit -framework QuartzCore \
              -framework ModelIO

EXAMPLES := 01-triangle 02-cube 03-particles 04-raymarch 05-ocean 06-tugboat 07-netbreach 08-warsim 09-biome 10-critterstyles
BINARIES := $(EXAMPLES:%=build/%)

all: $(BINARIES)

build/%: %/main.mm common/app.h | build
	$(CXX) $(CXXFLAGS) $< -o $@ $(FRAMEWORKS)

build:
	mkdir -p build

clean:
	rm -rf build

.PHONY: all clean
