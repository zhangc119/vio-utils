Heat templates to install wordpress application through Vmware Integrated Openstack (inspired by https://github.com/miguelgrinberg/heat-tutorial)

[Note] Remember to download "lib" folder as well when you want to use top heat_*.yaml. 

1) heat_wp.yaml
------------------------------------------------------

1.1) Network topology
------------------------------------------------------
![heat_wp](https://raw.githubusercontent.com/zhangc119/vio-utils/master/heat/doc-images/heat_wp.tiff)

1.2) Validation - http://floating_ip_address , a wordpress installation page shows up.

2) heat_wp_ha.yaml
------------------------------------------------------

2.1) Network topology
------------------------------------------------------
![heat_wp_ha](https://raw.githubusercontent.com/zhangc119/vio-utils/master/heat/doc-images/heat_wp_ha.tiff)

2.2) Instances under private network "wordpress_network":
A wordpress cluster plus one load balancer. Floating ip is associated with load balancer.

2.3) Validation - http://floating_ip_addr, a wordpress installation page shows up. It's roundrobin balancer, so refresh the ip multiple times to check all wordpress instances work fine. 

2.4) Samples :

- create one mysql, 3 wordpress VMs and one load balancer with two 2GB volumes attached each:

heat stack-create wordpress_ha -f heat_wp_ha.yaml -P "public_network_id=***;key=;wordpress_cluster_size=3;volume_count=2;volume_size=2"

- scale-out wordpress cluster:

heat stack-update wordpress_ha -f heat_wp_ha.yaml -P "public_network_id=***;key=;wordpress_cluster_size=5;volume_count=2;volume_size=2"

3) heat_wp_as.yaml
------------------------------------------------------
Template that installs wordpress cluster on LBaaS and supporting MySQL database running on separate server. The cluster supports auto scaling out/in via ceilometer cpu_util alarm
