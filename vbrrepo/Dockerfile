FROM ubuntu:20.04

# Install core packages, configure SSHD, add veeam user
RUN apt-get -q -y update; apt-get -q -y upgrade && \
    DEBIAN_FRONTEND=noninteractive apt-get -q -y install openssh-server perl pwgen xfsprogs && \
    apt-get clean autoclean && apt-get autoremove --yes && \
    rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_*_key* && mkdir /var/run/sshd && \
    sed -ri 's/^#?Port\s+.*/Port 22222/' /etc/ssh/sshd_config && \
    sed -ri 's/^#?HostKey \/etc\/ssh\/ssh_host_rsa_key/HostKey \/keys\/ssh_host_rsa_key/g' /etc/ssh/sshd_config && \
    sed -ri 's/^#?HostKey \/etc\/ssh\/ssh_host_ecdsa_key/HostKey \/keys\/ssh_host_ecdsa_key/g' /etc/ssh/sshd_config && \
    sed -ri 's/^#?HostKey \/etc\/ssh\/ssh_host_ed25519_key/HostKey \/keys\/ssh_host_ed25519_key/g' /etc/ssh/sshd_config && \
    sed -ri 's/^#?PermitRootLogin\s+.*/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -ri 's/UsePAM yes/UsePAM no/g' /etc/ssh/sshd_config && \
    sed -ri 's/^#?PasswordAuthentication\s+.*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    echo "ClientAliveInterval 30" >> /etc/ssh/sshd_config && \
    echo "ClientAliveCountMax 28800" >> /etc/ssh/sshd_config && \
    echo "TCPKeepAlive yes" >> /etc/ssh/sshd_config && \
    echo "MaxSessions 200" >> /etc/ssh/sshd_config && \
    echo "MaxStartups 100:30:200" >> /etc/ssh/sshd_config && \
    useradd -m -d /home/veeam -s /bin/bash veeam && \
    mkdir /home/veeam/.ssh && chmod 700 /home/veeam/.ssh && \
    mkdir -p /opt/veeam && mkdir /repo && \
    echo "#!/bin/bash\n" > /entrypoint.sh && \
    echo "if [ -z \"\$REPO_VOL\" ]\nthen" >> /entrypoint.sh && \
    echo "\"No Repository Volume Specified!!\"\n  exit 1\nfi" >> /entrypoint.sh && \
    echo "mount \$REPO_VOL /repo" >> /entrypoint.sh && \
    echo "cp /keys/veeam-auth-key.pub /home/veeam/.ssh/authorized_keys" >> /entrypoint.sh && \
    echo "chmod 600 /home/veeam/.ssh/authorized_keys" >> /entrypoint.sh && \
    echo "chown veeam.veeam -R /home/veeam /opt/veeam /repo" >> /entrypoint.sh && \
    echo "echo \"veeam:\$(pwgen -sy 48 1)\" | chpasswd\nexec /usr/sbin/sshd -D\n" >> /entrypoint.sh && \
    chmod +x /entrypoint.sh

# Ports must be published using -p during run 
EXPOSE 22222
EXPOSE 2500-3300

ENTRYPOINT ["/entrypoint.sh"]
