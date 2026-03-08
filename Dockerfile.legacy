FROM sonroyaalmerol/steamcmd-arm64:root
RUN ln -s /home/steam/steamcmd/steamcmd.sh /usr/local/bin/steamcmd
COPY steam_deploy.sh /root/steam_deploy.sh
ENTRYPOINT ["/root/steam_deploy.sh"]
