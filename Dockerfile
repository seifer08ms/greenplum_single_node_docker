# Greenplum Database (GPDB) "Single Node" Dockerized for testing purposes only.

# NOTES:
#
# Most useful GPDB docs I found:
# http://gpdb.docs.pivotal.io/gs/43/pdf/GPDB43xGettingStarted.pdf
#
# Loosely based on "Dockerfile for Greenplum SNE 4.2.6.1": https://gist.github.com/teraflopx/a0af37a880164da87198#comments
#
# Useful Docker commands:
# docker build -t greenplumdb_singlenode .
# docker run -i -p 5432:5432 -t greenplumdb_singlenode
# docker ps ... docker exec -it <running container name> bash
#
# Test that it's working by accessing it via PSQL:
# docker-machine ip default
# psql -h 192.168.99.100 -p 5432 -U gpadmin template1
#

FROM centos:6.6
MAINTAINER kevinmtrowbridge@gmail.com

RUN yum update -y #&& yum upgrade -y
RUN yum install -y unzip  python27 tar wget curl apr-devel \
libyaml-devel libevent-devel sudo openssh-server \
git curl-devel bzip2-devel python-devel openssl-devel\
 perl-ExtUtils-Embed  libxml2-devel openldap-devel   \
 pam pam-devel  perl-devel python-setuptools wget  gcc\
 readline readline-devel  make bison flex libxml2 \
 libxml2-devel libxslt libxslt-devel  gcc gcc-c++ \
 openssl-devel apr-devel libyaml-devel libevent-devel\
 net-tools  which python-py ed sed openssh-clients
RUN yum clean all
RUN echo root:docker | chpasswd
RUN echo "gpadmin ALL=(ALL) ALL" >> /etc/sudoers
WORKDIR "/tmp"
RUN wget https://bootstrap.pypa.io/get-pip.py && python get-pip.py && pip install psi lockfile paramiko setuptools epydoc

# CENTOS MODIFICATIONS

# It's dubious how well the sysctl.conf settings are working ... there's also the option of tuning the kernel
# at runtime (using docker run -w) ...
COPY centos/etc_sysctl.conf /tmp/sysctl.conf
RUN cat /tmp/sysctl.conf >> /etc/sysctl.conf

COPY centos/etc_security_limits.conf /tmp/limits.conf
RUN cat /tmp/limits.conf >> /etc/security/limits.conf
RUN rm /etc/security/limits.d/90-nproc.conf


# CUE GPADMIN USER

RUN groupadd -g 8000 gpadmin
RUN useradd -m -s /bin/bash -d /home/gpadmin -g gpadmin -u 8000 gpadmin
RUN echo "gpadmin" | passwd gpadmin --stdin

# NECESSARY: key exchange with ourselves - needed by single-node greenplum and hadoop
RUN service sshd start && ssh-keygen -t rsa -q -f /root/.ssh/id_rsa -P "" &&\
  cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys && ssh-keyscan -t rsa localhost >> /root/.ssh/known_hosts &&\
  ssh-keyscan -t rsa localhost >> /root/.ssh/known_hosts

RUN mkdir -p /data/gpmaster /data/gpdata1 /data/gpdata2
RUN chown -R gpadmin:gpadmin /data

# COPY GPDB FILES INTO PLACE
#COPY greenplum-db-appliance-4.3.7.1-build-1-RHEL5-x86_64.bin greenplum-db-appliance-4.3.7.1-build-1-RHEL5-x86_64.bin
RUN echo "localhost" > hostfile
RUN service sshd start && git clone --depth 1 https://github.com/greenplum-db/gpdb && cd gpdb && \
 ./configure --prefix=/home/gpadmin/greenplum-db --with-gssapi --with-pgport=5432 \
--with-libedit-preferred --with-perl --with-python --with-openssl --with-pam --with-krb5\
--with-ldap --with-libxml --enable-cassert --enable-debug --enable-testutils \
--enable-debugbreak --enable-depend && make -j4 && make install

ENV GPHOME /home/gpadmin/greenplum-db

WORKDIR /home/gpadmin
COPY bash/.gpadmin_bash_profile .bash_profile
RUN cat .bash_profile >> .bashrc
COPY gpdb/hostlist_singlenode hostlist_singlenode
COPY gpdb/gpinitsystem_singlenode gpinitsystem_singlenode

RUN chown -R gpadmin:gpadmin /home/gpadmin

RUN service sshd start && su gpadmin -l -c "gpssh-exkeys -h localhost"

# INITIALIZE GPDB SYSTEM
# HACK: note, capture of unique docker hostname -- at this point, the hostname gets embedded into the installation ... :(
RUN service sshd start &&\
 hostname > /docker_hostname_at_moment_of_gpinitsystem &&\
 su gpadmin -l -c "gpinitsystem -a -D -c /home/gpadmin/gpinitsystem_singlenode;"; exit 0;


# HACK: docker_transient_hostname_workaround, explanation:
#
# When gpinitsystem runs, it embeds the hostname (at that moment) into the installation.  Since Docker generates a new
# random hostname each time it runs, the hostname that is embedded, will never work again.  When you run `gpstart`, if
# the embedded hostname is not a valid DNS name, it will fail with this error:
#
# gpadmin-[ERROR]:-gpstart failed.  exiting...
# <snip>
#    addrinfo = socket.getaddrinfo(hostToPing, None)
# gaierror: [Errno -2] Name or service not known
#
# (You can reproduce this by removing the `docker_transient_hostname_workaround` bit from the CMD at the bottom.)
#
# So what we do here is to capture the random hostname at the moment that gpinitsystem is run, and later we can append
# it to /etc/hosts when we run `gpstart` -- this seems to keep it happy.
#
COPY bash/docker_transient_hostname_workaround.sh docker_transient_hostname_workaround.sh
RUN chmod +x docker_transient_hostname_workaround.sh


# WIDE OPEN GPDB ACCESS PERMISSIONS
COPY gpdb/allow_all_incoming_pg_hba.conf /data/gpmaster/gpsne-1/pg_hba.conf
COPY gpdb/postgresql.conf /data/gpmaster/gpsne-1/postgresql.conf

EXPOSE 5432

# THIS DOCKER IMAGE WILL BE USED FOR TESTING SO WE DON'T CARE ABOUT THE DATA, AT ALL
# VOLUME ["/data"]


CMD ./docker_transient_hostname_workaround.sh && service sshd start &&\
  echo "*******************************************************************" &&\
  echo $'\t' $'\t' "greenplum single-node sandbox in Docker" &&\
  echo  $'\t'$'\t' "user:gpadmin pass:gpadmin'" &&\
  su gpadmin # -l -c "gpstart -a --verbose" && sleep 86400 # HACK: it's difficult to get Docker to attach to the GPDB process(es) ... so, instead attach to process "sleep for 1 day"
