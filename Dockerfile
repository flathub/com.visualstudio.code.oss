FROM fedora:latest
RUN dnf install -yq flatpak flatpak-builder xz
RUN adduser -U -m user
USER user
WORKDIR /home/user
ADD --chown=user:user . .
CMD ["/bin/bash", "-xe", "flatpak.sh"]
