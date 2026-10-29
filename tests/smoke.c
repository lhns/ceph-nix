// Loads librados, librbd and libcephfs and builds a CephContext in each client library.
#include <stdio.h>
#include <cephfs/libcephfs.h>
#include <rados/librados.h>
#include <rbd/librbd.h>

int main(void)
{
	int major, minor, extra;
	rados_t cluster;
	struct ceph_mount_info *mount;

	rados_version(&major, &minor, &extra);
	printf("librados %d.%d.%d\n", major, minor, extra);
	rbd_version(&major, &minor, &extra);
	printf("librbd %d.%d.%d\n", major, minor, extra);
	printf("libcephfs %s\n", ceph_version(&major, &minor, &extra));

	if (rados_create(&cluster, "admin") || rados_conf_set(cluster, "mon_host", "127.0.0.1"))
		return 1;
	rados_shutdown(cluster);
	if (ceph_create(&mount, "admin") || ceph_conf_set(mount, "mon_host", "127.0.0.1"))
		return 1;
	ceph_release(mount);
	puts("ok");
	return 0;
}
