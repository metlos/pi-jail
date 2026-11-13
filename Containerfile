FROM registry.fedoraproject.org/fedora:44

# /home dir setup
RUN mkdir -p /home
ENV HOME="/home"

# basics
RUN dnf update -y \
  && dnf install -y \
  git \
  ripgrep \
  fzf \
  fd \
  jq \
  uv \
  diffutils \
  patch \
  podman \
  python3 \
  python3-pip \
  npm \
  @development-tools \
  && dnf clean all

# jj
RUN curl -fsSL https://github.com/cargo-bins/cargo-binstall/releases/latest/download/cargo-binstall-x86_64-unknown-linux-musl.tgz \
  | tar xz -C /usr/local/bin \
  && cargo-binstall -y --strategies crate-meta-data jj-cli \
  && mv "${HOME}/.cargo/bin/jj" /usr/local/bin/

# seed the home dir
ENV HOME_SEED_DIR="/usr/local/share/home-seed"
COPY ./seed "${HOME_SEED_DIR}"
RUN chmod -R a+rX "${HOME_SEED_DIR}"

# pi
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent

# code-review-graph
RUN pip install code-review-graph

# the extensions we use
ENV PI_CODING_AGENT_DIR="${HOME_SEED_DIR}/.pi/agent"
RUN pi install npm:@tintinweb/pi-subagents \
  && pi install npm:pi-hermes-memory \
  && pi install npm:pi-web-access \
  && pi install npm:@tintinweb/pi-tasks \
  && pi install git:github.com/DietrichGebert/ponytail \
  && pi install npm:@evreke/pi-grill-deck \
  && pi install npm:pi-btw \
  && pi update --extensions

COPY ./scripts/entrypoint.sh /usr/bin

ENV PI_CODING_AGENT_DIR="${HOME}/.pi/agent"

WORKDIR "/work"

ENTRYPOINT [ "entrypoint.sh" ]
CMD [ "pi" ]
