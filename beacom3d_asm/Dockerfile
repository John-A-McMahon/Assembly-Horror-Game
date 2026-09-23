# Build/run environment for the 3D assembly edition.
# Build from the REPOSITORY ROOT so the game can read ../intro.txt, ../T.txt etc:
#   docker build -t beacom3d -f beacom3d_asm/Dockerfile .
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get -y update && apt-get -y install \
        gcc nasm make lolcat \
        libsdl2-dev libsdl2-image-dev libsdl2-ttf-dev \
        libgl1-mesa-dev libgl1-mesa-dri fonts-dejavu-core xvfb \
    && rm -rf /var/lib/apt/lists/*
ENV PATH="$PATH:/usr/games"
COPY . /root/game
WORKDIR /root/game/beacom3d_asm
RUN make
