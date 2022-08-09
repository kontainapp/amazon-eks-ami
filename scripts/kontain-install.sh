#!/usr/bin/env bash

TEMPLATE_DIR=${TEMPLATE_DIR:-/tmp/worker}

###############################################################################
### Kontain Install and cofiguration###########################################
###############################################################################
sudo mkdir /kontain_bin
sudo tar -xvf $TEMPLATE_DIR/kontain_bin.tar.gz -C $TEMPLATE_DIR

sudo chmod +x $TEMPLATE_DIR/kkm.run

# Install kkm driver
echo "build and install KKM driver"
sudo $TEMPLATE_DIR/kkm.run

# Install KM Binaries
sudo mkdir -p /opt/kontain/bin
sudo cp $TEMPLATE_DIR/km/km /opt/kontain/bin/km
sudo cp $TEMPLATE_DIR/container-runtime/krun /opt/kontain/bin/krun
sudo cp $TEMPLATE_DIR/cloud/k8s/deploy/shim/containerd-shim-krun-v2 /usr/bin/containerd-shim-krun-v2

#Initialize containerd
sudo mkdir -p /etc/containerd
sudo mkdir -p /etc/cni/net.d
sudo mkdir -p /etc/systemd/system/containerd.service.d
sudo cat <<EOF > sudo tee /etc/systemd/system/containerd.service.d/10-compat-symlink.conf
[Service]
ExecStartPre=/bin/ln -sf /run/containerd/containerd.sock /run/dockershim.sock
EOF

sudo sed -i s,SANDBOX_IMAGE,$PAUSE_CONTAINER,g /etc/eks/containerd/containerd-config.toml
sudo cp -v /etc/eks/containerd/containerd-config.toml /etc/containerd/config.toml
sudo cp -v /etc/eks/containerd/sandbox-image.service /etc/systemd/system/sandbox-image.service
sudo cp -v /etc/eks/containerd/kubelet-containerd.service /etc/systemd/system/kubelet.service
sudo chown root:root /etc/systemd/system/kubelet.service
sudo chown root:root /etc/systemd/system/sandbox-image.service

#install Kontain runtime
containerd_conf_file="/etc/eks/containerd/containerd-config.toml"
runtime="krun"
configuration="configuration"
pluginid=cri

if grep -q "version = 2\>" $containerd_conf_file; then
    pluginid=\"io.containerd.grpc.v1.cri\"
fi

runtime_table="plugins.${pluginid}.containerd.runtimes.$runtime"
runtime_type="io.containerd.$runtime.v2"
options_table="$runtime_table.options"
config_path=""

cat <<EOT | sudo tee -a $containerd_conf_file
[$runtime_table]
runtime_type = "${runtime_type}"
privileged_without_host_devices = true
pod_annotations = ["app.kontain.*"]
EOT

# Make containerd default for bootstrap.sh
sudo sed -i -e 's/CONTAINER_RUNTIME\:\-dockerd/CONTAINER_RUNTIME\:\-containerd/g' /etc/eks/bootstrap.sh
