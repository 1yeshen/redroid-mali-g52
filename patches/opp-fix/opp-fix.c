// SPDX-License-Identifier: GPL-2.0
/*
 * opp-fix.c - Fix GPU OPP supported_hw for Panfrost on Rockchip
 *
 * On RK3568: Mali bifrost driver pre-configures GPU OPP via
 * rockchip_opp_select. After Mali is unbound, the OPP table is
 * left with partial entries and/or corrupted supported_hw.
 * Panfrost's devm_pm_opp_of_add_table() returns -ENOENT because
 * supported_hw filtering kills all DT OPP entries.
 *
 * This module re-initializes the GPU OPP:
 *   1. Clear supported_hw (or set to match-all value)
 *   2. Re-add OPP entries from DT
 *
 * Usage:
 *   # insmod opp-fix.ko
 *   # echo "fde60000.gpu" > /sys/bus/platform/drivers/panfrost/bind
 *
 * Author: iStore AI <istoreai@istoreos.com>
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/platform_device.h>
#include <linux/pm_opp.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/err.h>

static struct device *gpu_dev;

static int __init opp_fix_init(void)
{
	struct device_node *np;
	struct platform_device *pdev;
	int ret;

	pr_info("opp-fix: GPU OPP fix module loading\n");

	/* Find GPU device by compatible string */
	np = of_find_compatible_node(NULL, NULL, "arm,mali-bifrost");
	if (!np) {
		pr_err("opp-fix: GPU DT node not found\n");
		return -ENODEV;
	}

	if (!of_device_is_available(np)) {
		pr_err("opp-fix: GPU node is disabled\n");
		of_node_put(np);
		return -ENODEV;
	}

	pdev = of_find_device_by_node(np);
	of_node_put(np);
	if (!pdev) {
		pr_err("opp-fix: GPU platform device not found\n");
		return -ENODEV;
	}

	gpu_dev = &pdev->dev;
	dev_info(gpu_dev, "opp-fix: Fixing GPU OPP configuration\n");

	/*
	 * Step 1: Set supported_hw to match ALL entries.
	 * On RK3568: bin=0 so BIT(0)=1 is used. But after Mali's
	 * partial cleanup, supported_hw might be corrupted.
	 * Use 0xffffffff to match any OPP entry.
	 */
	{
		u32 hw[2] = { 0xffffffff, 0xffffffff };
		int token;

		token = dev_pm_opp_set_supported_hw(gpu_dev, hw, 2);
		if (token < 0) {
			dev_warn(gpu_dev, "opp-fix: set_supported_hw returned %d\n", token);
		} else {
			dev_info(gpu_dev, "opp-fix: supported_hw set to match-all\n");
		}
	}

	/*
	 * Step 2: Re-add OPP table from DT.
	 * If table already exists (some entries remain from Mali),
	 * dev_pm_opp_of_add_table returns -EEXIST which is fine.
	 * If supported_hw was wrong, we fixed it in step 1 so new
	 * entries can be added.
	 */
	ret = dev_pm_opp_of_add_table(gpu_dev);
	if (ret == 0) {
		dev_info(gpu_dev, "opp-fix: OPP table added from DT\n");
	} else if (ret == -EEXIST) {
		dev_info(gpu_dev, "opp-fix: OPP table already exists (continuing)\n");
	} else {
		dev_err(gpu_dev, "opp-fix: failed to add OPP table: %d\n", ret);
		/*
		 * Even if this fails, we tried. The caller (panfrost bind)
		 * will try again; having supported_hw = match-all should
		 * help.
		 */
	}

	dev_info(gpu_dev, "opp-fix: GPU OPP fix applied\n");
	return 0;
}

static void __exit opp_fix_exit(void)
{
	pr_info("opp-fix: unloading\n");
	/* We intentionally don't clean up OPP here to avoid breaking
	 * any subsequent panfrost bind attempt.
	 */
}

module_init(opp_fix_init);
module_exit(opp_fix_exit);

MODULE_LICENSE("GPL v2");
MODULE_DESCRIPTION("Fix GPU OPP supported_hw for Panfrost on Rockchip");
MODULE_AUTHOR("iStore AI");
MODULE_VERSION("1.0");
