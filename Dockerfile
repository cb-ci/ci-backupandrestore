# Start by pulling the official Amazon Linux 2023 image
FROM amazonlinux:2023

# Set environment variables (optional but good practice)
ENV APP_HOME /usr/src/app
RUN mkdir -p $APP_HOME
WORKDIR $APP_HOME

# 1. Update packages and install required tools using DNF (the AL2023 package manager)
RUN dnf update -y && \
    dnf install -y \
        tar \
        gzip \
        wget \
        jq \
	    unzip \
	    findutils \
        htop && \
    dnf clean all
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf awscliv2.zip aws
# 2. Copy your application code into the image
# COPY . $APP_HOME

# 3. Define the port the container listens on (if it runs a server)
# EXPOSE 8080

# 4. Define the command to run when the container starts
# CMD ["/usr/bin/htop"]