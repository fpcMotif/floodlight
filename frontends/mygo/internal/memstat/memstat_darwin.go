package memstat

/*
#include <mach/mach.h>

static int fl_task_vm(uint64_t *rss, uint64_t *footprint) {
	task_vm_info_data_t info;
	mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
	if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
		return -1;
	}
	*rss = info.resident_size;
	*footprint = info.phys_footprint;
	return 0;
}
*/
import "C"

import "errors"

// Read returns resident size and physical footprint from task_info.
func Read() (Stat, error) {
	var rss, fp C.uint64_t
	if C.fl_task_vm(&rss, &fp) != 0 {
		return Stat{}, errors.New("memstat: task_info failed")
	}
	return Stat{RSS: uint64(rss), Footprint: uint64(fp)}, nil
}
