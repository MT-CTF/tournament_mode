# syntax=docker/dockerfile:1

################################################################################

FROM alpine:latest as base

WORKDIR /

RUN apk add --no-cache build-base readline unzip libpng-dev jpeg-dev mesa-dev sqlite-dev libogg-dev libvorbis-dev openal-soft-dev curl-dev freetype-dev zlib-dev gmp-dev jsoncpp-dev zstd-dev gettext sdl2-dev
RUN apk add --no-cache git curl wget grep python3 sqlite redis

RUN git clone https://luajit.org/git/luajit.git
WORKDIR /luajit/
RUN make -j $(nproc)
RUN make -j $(nproc) install
WORKDIR /

RUN wget https://luarocks.github.io/luarocks/releases/luarocks-3.13.0.tar.gz -O - | tar -xzf -
WORKDIR /luarocks-3.13.0/
RUN ./configure --with-lua-include=/usr/local/include/
RUN make -j $(nproc)
RUN make -j $(nproc) install
WORKDIR /
RUN luarocks config variables.LUA_INCDIR /usr/local/include/luajit-2.1/

# Only needed if we're using the redis rankings backend
# RUN git clone https://github.com/hnimminh/luaredis.git
# WORKDIR /luaredis/
# RUN luarocks make
# WORKDIR /

RUN luarocks install lsqlite3

FROM base as build

RUN apk add --no-cache cmake

RUN git clone --depth 1 https://github.com/luanti-org/luanti.git ./luanti/

WORKDIR /luanti/

COPY ./patches/*.patch ./
RUN git -c user.name="CTFDocker" -c user.email="" am ./*.patch

RUN cmake . -DCMAKE_BUILD_TYPE=Release -DRUN_IN_PLACE=TRUE -DBUILD_SERVER=TRUE -DBUILD_CLIENT=FALSE -DENABLE_LUAJIT=TRUE -DREQUIRE_LUAJIT=TRUE

RUN make -j $(nproc)

RUN git -C ./games/ clone --recursive https://github.com/MT-CTF/capturetheflag.git

RUN LUANTI_VERSION="041a7a60031eacce40a2d7c7b73cf6ee8acfe037"

RUN git remote update
RUN git checkout $LUANTI_VERSION

RUN git -C ./games/capturetheflag/ pull -r

WORKDIR /

FROM base AS final

ARG UID=1000
RUN addgroup -g "${UID}" luanti
RUN adduser \
    --disabled-password \
    --gecos "" \
    --home "/home/luanti/" \
    --shell "/sbin/nologin" \
    --uid "${UID}" \
    -G luanti \
    luanti

# Copy luanti
COPY --from=build --chown=luanti ./luanti/ /home/luanti/luanti/

EXPOSE 30007

USER luanti

RUN mkdir -p /home/luanti/tournament_server/
RUN chown luanti:luanti /home/luanti/tournament_server/
VOLUME ["/home/luanti/tournament_server/"]


WORKDIR /home/luanti/tournament_server/

ENTRYPOINT ["sh", "start_server.sh" ]