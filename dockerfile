FROM ubuntu:latest
RUN apt-get -y update
RUN apt-get -y upgrade
RUN apt-get -y install lolcat
RUN apt-get -y install gcc
RUN apt-get -y install nasm
RUN apt-get -y install make
RUN apt-get -y install gcc-multilib g++-multilib libc6-dev-i386
RUN apt-get -y install libsdl2-dev
RUN apt-get -y install libsdl2-image-dev
RUN echo "export PATH=$PATH:/usr/games" >> /root/.bashrc


COPY . /root/game

WORKDIR /root/game
