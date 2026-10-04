FROM fchaussin/quizdock:standalone

# Add only the tools needed by the persistent-backup wrapper.
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-boto3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --chown=quizdock:quizdock render-start.sh /usr/local/bin/render-start.sh
COPY --chown=quizdock:quizdock b2_backup.py /usr/local/bin/b2_backup.py
RUN chmod 0755 /usr/local/bin/render-start.sh /usr/local/bin/b2_backup.py

# Render supplies PORT=10000. Keep the image healthcheck aligned with that value.
HEALTHCHECK --interval=15s --timeout=5s --start-period=90s --retries=8 \
  CMD-SHELL node -e "const p=process.env.PORT||'10000'; fetch('http://127.0.0.1:'+p+'/health/ready').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

USER quizdock
EXPOSE 10000
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/render-start.sh"]
