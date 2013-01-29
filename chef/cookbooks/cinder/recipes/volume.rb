#
# Copyright 2012 Dell, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Cookbook Name:: cinder
# Recipe:: volume
#

include_recipe "#{@cookbook_name}::common"

volname = node[:cinder][:volume][:volume_name]

checked_disks = []

node[:crowbar][:disks].each do |disk, data|
  checked_disks << disk if File.exists?("/dev/#{disk}") and data["usage"] == "Storage"
end

if checked_disks.empty? or node[:cinder][:volume][:volume_type] == "local"
  # only OS disk is exists, will use file storage
  fname = node["cinder"]["volume"]["local_file"]
  fdir = ::File.dirname(fname)
  fsize = node["cinder"]["volume"]["local_size"] * 1024 * 1024 * 1024 # Convert from GB to Bytes

  #this code will be executed at compile-time so we have to use ruby block or get fs capacity from parent directory because at compile-time we have no package resources done
  #creating enclosing directory and user/group here bypassing packages looks like a bad idea. I'm not sure about postinstall behavior of cinder package.
  # Cap size at 90% of free space
  encl_dir=fdir
  while not File.directory?(encl_dir)
    encl_dir=encl_dir.sub(/\/[^\/]*$/,'')
  end
  max_fsize = ((`df -Pk #{encl_dir}`.split("\n")[1].split(" ")[3].to_i * 1024) * 0.90).to_i rescue 0
  fsize = max_fsize if fsize > max_fsize

  bash "create local volume file #{fname}" do
    code "truncate -s #{fsize} #{fname}"
    not_if do
      File.exists?(fname)
    end
  end

  bash "setup loop device for volume #{fname}" do
    code "losetup -f --show #{fname}"
    not_if "losetup -j #{fname} | grep #{fname}"
  end

  bash "create volume group #{volname}" do
    code "vgcreate #{volname} `losetup -j #{fname} | cut -f1 -d:`"
    not_if "vgs #{volname}"
  end

elsif node[:cinder][:volume][:volume_type] == "eqlx"
  # do nothing on the host
else
  raw_mode = node[:cinder][:volume][:cinder_raw_method]
  raw_list = node[:cinder][:volume][:cinder_volume_disks]
  # if all, then just use the checked_list
  raw_list = checked_disks if raw_mode == "all"

  if raw_list.empty? or raw_mode == "first"
    # use first non-OS disk for vg
    dname = "/dev/#{checked_disks.first}"
    bash "wipe partitions #{dname}" do
      code "dd if=/dev/zero of=#{dname} bs=1024 count=1"
      not_if "vgs #{volname}"
    end
  else
    # use this disk list
    disk_list = []
    raw_list.each do |disk|
      disk_list << "/dev/#{disk}" if checked_disks.include?(disk)
      bash "wipe partitions #{disk}" do
        code "dd if=/dev/zero of=#{disk} bs=1024 count=1"
        not_if "vgs #{volname}"
      end
    end
    raise "Can't access any disk from the given list" if disk_list.empty?
    dname = disk_list.join(' ')
  end

  bash "create physical volume #{dname}" do
    code "pvcreate #{dname}"
    not_if "pvs #{dname}"
  end

  bash "create volume group #{volname}" do
    code "vgcreate #{volname} #{dname}"
    not_if "vgs #{volname}"
  end

end

#
# Put EQLX driver
# It's kinda hacky
#
if node[:cinder][:volume][:volume_type] == "eqlx"
  package("python-paramiko")
  #TODO(agordeev): use path_spec not hardcode
  if node[:cinder][:use_gitrepo]
    eqlx_path = "/opt/cinder/cinder/volume/eqlx.py"
  else
    eqlx_path = "/usr/lib/python2.7/dist-packages/cinder/volume/eqlx.py"
  end
  cookbook_file eqlx_path do
    mode "0755"
    source "eqlx.py"
  end
end

package "tgt"
if node[:cinder][:use_gitrepo]
  #TODO(agordeev):
  # tgt will not work with iSCSI targets if it has the same configs in conf.d
  # e.g. cinder_tgt.conf (which comes from packages) and cinder-volume.conf
  # with the same data such as 'include /var/lib/cinder/volumes/*'
  cookbook_file "/etc/tgt/conf.d/cinder-volume.conf" do
    source "cinder-volume.conf"
  end
end

cinder_service("volume")

# Restart doesn't work correct for this service.
service "tgt" do
  supports :status => true, :restart => true, :reload => true
  action :enable
  restart_command "stop tgt ; start tgt"
  #notifies :run, "bash[restart-tgt_#{@cookbook_name}]"
end

#workaround for crappy perl-style tgt's config parser
#https://bugs.launchpad.net/devstack/+bug/1072121 somehow related
to_include=Dir["/etc/tgt/conf.d/*.conf"]
template "/etc/tgt/targets.conf" do
  source "tgt_targets.conf.erb"
  notifies :restart, "service[tgt]"
  variables(
    :tgt_confs => to_include
  )
end

