set -e -x

# If USE_LEGACY_OPENGL is not set, default to "0"
USE_LEGACY_OPENGL="${USE_LEGACY_OPENGL:-0}"

# macOS SDL3
MACOS__SDL3__VERSION="3.2.14"
MACOS__SDL3__URL="https://github.com/libsdl-org/SDL/releases/download/release-$MACOS__SDL3__VERSION/SDL3-$MACOS__SDL3__VERSION.tar.gz"
MACOS__SDL3__FOLDER="SDL3-$MACOS__SDL3__VERSION"

# macOS SDL3_image
MACOS__SDL3_IMAGE__VERSION="3.2.4"
MACOS__SDL3_IMAGE__URL="https://github.com/libsdl-org/SDL_image/releases/download/release-$MACOS__SDL3_IMAGE__VERSION/SDL3_image-$MACOS__SDL3_IMAGE__VERSION.tar.gz"
MACOS__SDL3_IMAGE__FOLDER="SDL3_image-$MACOS__SDL3_IMAGE__VERSION"

# macOS SDL3_mixer
# MACOS__SDL2_MIXER__VERSION="2.6.3"
# MACOS__SDL2_MIXER__URL="https://github.com/libsdl-org/SDL_mixer/releases/download/release-$MACOS__SDL2_MIXER__VERSION/SDL2_mixer-$MACOS__SDL2_MIXER__VERSION.tar.gz"
# MACOS__SDL2_MIXER__FOLDER="SDL2_mixer-${MACOS__SDL2_MIXER__VERSION}"
MACOS__SDL3_MIXER__HASH="78a2035cf4cf95066d7d9e6208e99507376409a7"
MACOS__SDL3_MIXER__URL="https://github.com/libsdl-org/SDL_mixer/archive/$MACOS__SDL3_MIXER__HASH.tar.gz"
MACOS__SDL3_MIXER__FOLDER="SDL_mixer-$MACOS__SDL3_MIXER__HASH"

# macOS SDL3_ttf
MACOS__SDL3_TTF__VERSION="3.2.2"
MACOS__SDL3_TTF__URL="https://github.com/libsdl-org/SDL_ttf/releases/download/release-$MACOS__SDL3_TTF__VERSION/SDL3_ttf-$MACOS__SDL3_TTF__VERSION.tar.gz"
MACOS__SDL3_TTF__FOLDER="SDL3_ttf-$MACOS__SDL3_TTF__VERSION"

# macOS libpng
MACOS__LIBPNG__VERSION="1.6.47"
MACOS__LIBPNG__URL="https://download.sourceforge.net/libpng/libpng16/${MACOS__LIBPNG__VERSION}/libpng-${MACOS__LIBPNG__VERSION}.tar.gz"
MACOS__LIBPNG__FOLDER="libpng-${MACOS__LIBPNG__VERSION}"

MACOS__ANGLE__VERSION="chromium-6943_rev1"
MACOS__ANGLE_URL="https://github.com/kivy/angle-builder/releases/download/${MACOS__ANGLE__VERSION}/angle-macos-universal.tar.gz"
MACOS__ANGLE__FOLDER="angle-macos-universal"

# Clean the dependencies folder
rm -rf kivy-dependencies

# Create the dependencies folder
mkdir kivy-dependencies

# Download the dependencies
echo "Downloading dependencies..."
mkdir kivy-dependencies/download
pushd kivy-dependencies/download
curl -L $MACOS__SDL3__URL -o "${MACOS__SDL3__FOLDER}.tar.gz"
curl -L $MACOS__SDL3_IMAGE__URL -o "${MACOS__SDL3_IMAGE__FOLDER}.tar.gz"
curl -L $MACOS__SDL3_MIXER__URL -o "${MACOS__SDL3_MIXER__FOLDER}.tar.gz"
curl -L $MACOS__SDL3_TTF__URL -o "${MACOS__SDL3_TTF__FOLDER}.tar.gz"
curl -L $MACOS__LIBPNG__URL -o "${MACOS__LIBPNG__FOLDER}.tar.gz"
curl -L $MACOS__ANGLE_URL -o "${MACOS__ANGLE__FOLDER}.tar.gz"
popd

# Extract the dependencies into build folder
echo "Extracting dependencies..."
mkdir kivy-dependencies/build
pushd kivy-dependencies/build
tar -xzf ../download/${MACOS__SDL3__FOLDER}.tar.gz
tar -xzf ../download/${MACOS__SDL3_IMAGE__FOLDER}.tar.gz
tar -xzf ../download/${MACOS__SDL3_MIXER__FOLDER}.tar.gz
tar -xzf ../download/${MACOS__SDL3_TTF__FOLDER}.tar.gz
tar -xzf ../download/${MACOS__LIBPNG__FOLDER}.tar.gz
popd

# Create distribution folder
echo "Creating distribution folder..."
mkdir kivy-dependencies/dist
mkdir kivy-dependencies/dist/Frameworks
mkdir kivy-dependencies/dist/include
mkdir kivy-dependencies/dist/lib

if [ "$USE_LEGACY_OPENGL" = "0" ]; then
        # Extract ANGLE in distribution folder
        echo "Extracting ANGLE..."
        pushd kivy-dependencies/dist
        mkdir $MACOS__ANGLE__FOLDER
        tar -xzf ../download/${MACOS__ANGLE__FOLDER}.tar.gz -C $MACOS__ANGLE__FOLDER
        cp -a ${MACOS__ANGLE__FOLDER}/include/* include
        cp ${MACOS__ANGLE__FOLDER}/*.dylib lib
        rm -r $MACOS__ANGLE__FOLDER
        popd
else

        echo "Using legacy OpenGL, not extracting ANGLE..."
fi

LIBPNG_SEARCH_PATH="$(pwd)/kivy-dependencies/dist/Frameworks/png.framework/Headers"
FRAMEWORK_SEARCH_PATHS="$(pwd)/kivy-dependencies/dist/Frameworks"

# Build the dependencies
pushd kivy-dependencies/build

# libpng is neeeded by SDL3_ttf to render emojis
echo "-- Build libpng (Universal)"
pushd $MACOS__LIBPNG__FOLDER
  cmake -S . -B build \
          -DCMAKE_INSTALL_PREFIX=../../dist \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_OSX_ARCHITECTURES="x86_64;arm64" \
          -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15 \
          -DPNG_TESTS=OFF \
          -DPNG_EXECUTABLES=OFF \
          -DPNG_SHARED=OFF \
          -DPNG_STATIC=OFF \
          -DPNG_FRAMEWORK=ON \
          -DCMAKE_C_FLAGS="-DPNG_ARM_NEON_OPT=0" \
          -GNinja
  cmake --build build/ --config Release --verbose --parallel
  cmake --install build/ --config Release

# for some reason, the framework is installed in lib instead of Frameworks
cp -a ../../dist/lib/png.framework ../../dist/Frameworks

popd

echo "-- Build SDL3 (Universal)"
pushd $MACOS__SDL3__FOLDER
if [ "$USE_LEGACY_OPENGL" = "1" ]; then
        xcodebuild ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=10.15 \
                -project Xcode/SDL/SDL.xcodeproj -target SDL3 -configuration Release
else
        xcodebuild ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=10.15 \
                -project Xcode/SDL/SDL.xcodeproj -target SDL3 -configuration Release \
                GCC_PREPROCESSOR_DEFINITIONS='$(GCC_PREPROCESSOR_DEFINITIONS) SDL_VIDEO_OPENGL=0'
fi
cp -a Xcode/SDL/build/Release/SDL3.framework ../../dist/Frameworks
popd

echo "-- Build SDL3_mixer (Universal)"
pushd $MACOS__SDL3_MIXER__FOLDER
xcodebuild ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=10.15 \
        FRAMEWORK_SEARCH_PATHS='$(FRAMEWORK_SEARCH_PATHS) '"$FRAMEWORK_SEARCH_PATHS" \
        -project Xcode/SDL_mixer.xcodeproj -target SDL3_mixer -configuration Release
cp -a Xcode/build/Release/SDL3_mixer.framework ../../dist/Frameworks
popd

echo "-- Build SDL3_image (Universal)"
pushd $MACOS__SDL3_IMAGE__FOLDER
xcodebuild ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=10.15 \
        FRAMEWORK_SEARCH_PATHS='$(FRAMEWORK_SEARCH_PATHS) '"$FRAMEWORK_SEARCH_PATHS" \
        -project Xcode/SDL_image.xcodeproj -target SDL3_image -configuration Release
cp -a Xcode/build/Release/SDL3_image.framework ../../dist/Frameworks
popd

echo "-- Build SDL3_ttf (Universal)"
pushd $MACOS__SDL3_TTF__FOLDER
sh ./external/download.sh

xcodebuild ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=10.15 \
        -project Xcode/SDL_ttf.xcodeproj -target SDL3_ttf -configuration Release \
        GCC_PREPROCESSOR_DEFINITIONS='$(GCC_PREPROCESSOR_DEFINITIONS) FT_CONFIG_OPTION_USE_PNG=1' \
        FRAMEWORK_SEARCH_PATHS='$(FRAMEWORK_SEARCH_PATHS) '"$FRAMEWORK_SEARCH_PATHS" \
        HEADER_SEARCH_PATHS='$(HEADER_SEARCH_PATHS) '"$LIBPNG_SEARCH_PATH" \
        OTHER_LDFLAGS='$(OTHER_LDFLAGS) -framework png'

cp -a Xcode/build/Release/SDL3_ttf.framework ../../dist/Frameworks
popd

popd
