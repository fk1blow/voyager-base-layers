FROM debian:latest

# The ARM toolchain is installed here rather than left to `qmk setup`, which
# cannot install it: the workflow bind-mounts the qmk_firmware *submodule*, whose
# .git is a file pointing at ../.git/modules/qmk_firmware — outside the mount. QMK
# therefore sees "not a git repository", skips dependency installation, and the
# build dies on `arm-none-eabi-gcc: not found`.
# ARM only: the Voyager (and Moonlander) are STM32. The AVR geometries this
# workflow also offers would additionally need gcc-avr avr-libc binutils-avr.
RUN apt update && apt install -y \
      git python3 python3-pip sudo \
      gcc-arm-none-eabi binutils-arm-none-eabi libnewlib-arm-none-eabi \
      dfu-util dos2unix \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install qmk appdirs --break-system-packages

WORKDIR /root
