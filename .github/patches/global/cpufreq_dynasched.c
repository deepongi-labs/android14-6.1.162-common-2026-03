// SPDX-License-Identifier: GPL-2.0
/*
 * dynasched - Cluster-aware CPUFreq governor for Tensor G3 (Pixel 8 series).
 *
 * Extends schedutil with per-cluster asymmetric rate limits and util headroom
 * tuned for the X3 (prime), A715 (big), and A510 (little) clusters.
 *
 * Bias modes (selectable via sysfs):
 *   performance - fast up-ramp, slow down-ramp, boosted headroom on prime/big
 *   balanced    - symmetric ramps, moderate headroom (default)
 *   battery     - slow up-ramp, fast down-ramp, reduced headroom on little
 *
 * Cluster detection uses cpuinfo_max_freq at governor init:
 *   X3   (prime)  : max_freq >= DYNASCHED_PRIME_MIN_KHZ
 *   A715 (big)    : max_freq >= DYNASCHED_BIG_MIN_KHZ
 *   A510 (little) : max_freq <  DYNASCHED_BIG_MIN_KHZ
 */

#include <trace/hooks/sched.h>

#define IOWAIT_BOOST_MIN	(SCHED_CAPACITY_SCALE / 8)

/* Tensor G3 frequency thresholds (kHz) */
#define DYNASCHED_PRIME_MIN_KHZ		2800000
#define DYNASCHED_BIG_MIN_KHZ		2200000

/* Default rate limits per cluster per bias (microseconds) */
#define DYN_UP_PERF_PRIME		100
#define DYN_DOWN_PERF_PRIME		2000
#define DYN_UP_PERF_BIG			200
#define DYN_DOWN_PERF_BIG		2000
#define DYN_UP_PERF_LITTLE		500
#define DYN_DOWN_PERF_LITTLE		1000

#define DYN_UP_BAL_PRIME		500
#define DYN_DOWN_BAL_PRIME		1000
#define DYN_UP_BAL_BIG			500
#define DYN_DOWN_BAL_BIG		1000
#define DYN_UP_BAL_LITTLE		500
#define DYN_DOWN_BAL_LITTLE		1000

#define DYN_UP_BATT_PRIME		1000
#define DYN_DOWN_BATT_PRIME		500
#define DYN_UP_BATT_BIG			1000
#define DYN_DOWN_BATT_BIG		500
#define DYN_UP_BATT_LITTLE		2000
#define DYN_DOWN_BATT_LITTLE		200

/*
 * Util headroom multiplier (fixed-point, 256 = 1.0x).
 * Applied as: util = util * headroom >> 8
 * Values > 256 boost frequency selection above raw util.
 */
#define DYN_HEADROOM_PERF_PRIME		320	/* 1.25x */
#define DYN_HEADROOM_PERF_BIG		288	/* 1.125x */
#define DYN_HEADROOM_PERF_LITTLE	256	/* 1.0x */

#define DYN_HEADROOM_BAL_PRIME		288	/* 1.125x */
#define DYN_HEADROOM_BAL_BIG		272	/* 1.0625x */
#define DYN_HEADROOM_BAL_LITTLE		256	/* 1.0x */

#define DYN_HEADROOM_BATT_PRIME		256	/* 1.0x */
#define DYN_HEADROOM_BATT_BIG		240	/* 0.9375x */
#define DYN_HEADROOM_BATT_LITTLE	224	/* 0.875x */

enum dynasched_cluster {
	DYN_CLUSTER_LITTLE = 0,
	DYN_CLUSTER_BIG,
	DYN_CLUSTER_PRIME,
};

enum dynasched_bias {
	DYN_BIAS_BALANCED = 0,
	DYN_BIAS_PERFORMANCE,
	DYN_BIAS_BATTERY,
};

struct dynasched_tunables {
	struct gov_attr_set	attr_set;
	/* asymmetric rate limits in ns */
	s64			up_rate_limit_ns;
	s64			down_rate_limit_ns;
	/* util headroom multiplier (fixed-point, 256 = 1.0) */
	unsigned int		headroom;
	enum dynasched_bias	bias;
	enum dynasched_cluster	cluster;
};

struct dynasched_policy {
	struct cpufreq_policy	*policy;
	struct dynasched_tunables *tunables;
	struct list_head	tunables_hook;

	raw_spinlock_t		update_lock;
	u64			last_freq_update_time;
	u64			last_up_time;
	u64			last_down_time;
	unsigned int		next_freq;
	unsigned int		cached_raw_freq;

	struct irq_work		irq_work;
	struct kthread_work	work;
	struct mutex		work_lock;
	struct kthread_worker	worker;
	struct task_struct	*thread;
	bool			work_in_progress;

	bool			limits_changed;
	bool			need_freq_update;
};

struct dynasched_cpu {
	struct update_util_data	update_util;
	struct dynasched_policy	*dyn_policy;
	unsigned int		cpu;

	bool			iowait_boost_pending;
	unsigned int		iowait_boost;
	u64			last_update;

	unsigned long		util;
	unsigned long		bw_dl;
	unsigned long		max;

#ifdef CONFIG_NO_HZ_COMMON
	unsigned long		saved_idle_calls;
#endif
};

static DEFINE_PER_CPU(struct dynasched_cpu, dynasched_cpu);
static DEFINE_MUTEX(global_tunables_lock);
static struct dynasched_tunables *global_tunables;

/************************ Cluster detection ***********************/

static enum dynasched_cluster dyn_detect_cluster(struct cpufreq_policy *policy)
{
	unsigned int max_khz = policy->cpuinfo.max_freq;

	if (max_khz >= DYNASCHED_PRIME_MIN_KHZ)
		return DYN_CLUSTER_PRIME;
	if (max_khz >= DYNASCHED_BIG_MIN_KHZ)
		return DYN_CLUSTER_BIG;
	return DYN_CLUSTER_LITTLE;
}

static void dyn_apply_bias(struct dynasched_tunables *tunables)
{
	switch (tunables->bias) {
	case DYN_BIAS_PERFORMANCE:
		switch (tunables->cluster) {
		case DYN_CLUSTER_PRIME:
			tunables->up_rate_limit_ns   = DYN_UP_PERF_PRIME   * NSEC_PER_USEC;
			tunables->down_rate_limit_ns = DYN_DOWN_PERF_PRIME  * NSEC_PER_USEC;
			tunables->headroom           = DYN_HEADROOM_PERF_PRIME;
			break;
		case DYN_CLUSTER_BIG:
			tunables->up_rate_limit_ns   = DYN_UP_PERF_BIG      * NSEC_PER_USEC;
			tunables->down_rate_limit_ns = DYN_DOWN_PERF_BIG     * NSEC_PER_USEC;
			tunables->headroom           = DYN_HEADROOM_PERF_BIG;
			break;
		default:
			tunables->up_rate_limit_ns   = DYN_UP_PERF_LITTLE   * NSEC_PER_USEC;
			tunables->down_rate_limit_ns = DYN_DOWN_PERF_LITTLE  * NSEC_PER_USEC;
			tunables->headroom           = DYN_HEADROOM_PERF_LITTLE;
			break;
		}
		break;
	case DYN_BIAS_BATTERY:
		switch (tunables->cluster) {
		case DYN_CLUSTER_PRIME:
			tunables->up_rate_limit_ns   = DYN_UP_BATT_PRIME    * NSEC_PER_USEC;
			tunables->down_rate_limit_ns = DYN_DOWN_BATT_PRIME   * NSEC_PER_USEC;
			tunables->headroom           = DYN_HEADROOM_BATT_PRIME;
			break;
		case DYN_CLUSTER_BIG:
			tunables->up_rate_limit_ns   = DYN_UP_BATT_BIG       * NSEC_PER_USEC;
			tunables->down_rate_limit_ns = DYN_DOWN_BATT_BIG      * NSEC_PER_USEC;
			tunables->headroom           = DYN_HEADROOM_BATT_BIG;
			break;
		default:
			tunables->up_rate_limit_ns   = DYN_UP_BATT_LITTLE    * NSEC_PER_USEC;
			tunables->down_rate_limit_ns = DYN_DOWN_BATT_LITTLE   * NSEC_PER_USEC;
			tunables->headroom           = DYN_HEADROOM_BATT_LITTLE;
			break;
		}
		break;
	default: /* balanced */
		switch (tunables->cluster) {
		case DYN_CLUSTER_PRIME:
			tunables->up_rate_limit_ns   = DYN_UP_BAL_PRIME     * NSEC_PER_USEC;
			tunables->down_rate_limit_ns = DYN_DOWN_BAL_PRIME    * NSEC_PER_USEC;
			tunables->headroom           = DYN_HEADROOM_BAL_PRIME;
			break;
		case DYN_CLUSTER_BIG:
			tunables->up_rate_limit_ns   = DYN_UP_BAL_BIG        * NSEC_PER_USEC;
			tunables->down_rate_limit_ns = DYN_DOWN_BAL_BIG       * NSEC_PER_USEC;
			tunables->headroom           = DYN_HEADROOM_BAL_BIG;
			break;
		default:
			tunables->up_rate_limit_ns   = DYN_UP_BAL_LITTLE     * NSEC_PER_USEC;
			tunables->down_rate_limit_ns = DYN_DOWN_BAL_LITTLE    * NSEC_PER_USEC;
			tunables->headroom           = DYN_HEADROOM_BAL_LITTLE;
			break;
		}
		break;
	}
}

/************************ Governor internals ***********************/

static bool dyn_should_update_freq(struct dynasched_policy *dyn_policy,
				   u64 time, unsigned int next_freq)
{
	s64 delta_ns;

	if (!cpufreq_this_cpu_can_update(dyn_policy->policy))
		return false;

	if (unlikely(READ_ONCE(dyn_policy->limits_changed))) {
		WRITE_ONCE(dyn_policy->limits_changed, false);
		dyn_policy->need_freq_update = true;
		smp_mb();
		return true;
	}

	/* Asymmetric rate limiting: up vs down */
	if (next_freq > dyn_policy->next_freq)
		delta_ns = time - dyn_policy->last_up_time;
	else
		delta_ns = time - dyn_policy->last_down_time;

	if (next_freq > dyn_policy->next_freq)
		return delta_ns >= dyn_policy->tunables->up_rate_limit_ns;
	else
		return delta_ns >= dyn_policy->tunables->down_rate_limit_ns;
}

static bool dyn_update_next_freq(struct dynasched_policy *dyn_policy,
				 u64 time, unsigned int next_freq)
{
	if (dyn_policy->need_freq_update) {
		dyn_policy->need_freq_update = false;
		if (dyn_policy->next_freq == next_freq &&
		    !cpufreq_driver_test_flags(CPUFREQ_NEED_UPDATE_LIMITS))
			return false;
	} else if (dyn_policy->next_freq == next_freq) {
		return false;
	}

	if (next_freq > dyn_policy->next_freq)
		dyn_policy->last_up_time = time;
	else
		dyn_policy->last_down_time = time;

	dyn_policy->next_freq = next_freq;
	dyn_policy->last_freq_update_time = time;
	return true;
}

static void dyn_deferred_update(struct dynasched_policy *dyn_policy)
{
	if (!dyn_policy->work_in_progress) {
		dyn_policy->work_in_progress = true;
		irq_work_queue(&dyn_policy->irq_work);
	}
}

static void dyn_get_util(struct dynasched_cpu *dyn_cpu)
{
	struct rq *rq = cpu_rq(dyn_cpu->cpu);

	dyn_cpu->max    = arch_scale_cpu_capacity(dyn_cpu->cpu);
	dyn_cpu->bw_dl  = cpu_bw_dl(rq);
	dyn_cpu->util   = effective_cpu_util(dyn_cpu->cpu,
					     cpu_util_cfs(dyn_cpu->cpu),
					     FREQUENCY_UTIL, NULL);
}

/* Apply per-cluster headroom to util before frequency selection */
static unsigned long dyn_apply_headroom(struct dynasched_cpu *dyn_cpu)
{
	unsigned int headroom = dyn_cpu->dyn_policy->tunables->headroom;
	unsigned long util = dyn_cpu->util;

	/* util * headroom / 256, clamped to max */
	util = (util * headroom) >> 8;
	return min(util, dyn_cpu->max);
}

static unsigned int dyn_get_next_freq(struct dynasched_policy *dyn_policy,
				      unsigned long util, unsigned long max)
{
	struct cpufreq_policy *policy = dyn_policy->policy;
	unsigned int freq = arch_scale_freq_invariant() ?
			    policy->cpuinfo.max_freq : policy->cur;
	unsigned long next_freq = 0;

	util = map_util_perf(util);
	trace_android_vh_map_util_freq(util, freq, max, &next_freq, policy,
				       &dyn_policy->need_freq_update);
	if (next_freq)
		freq = next_freq;
	else
		freq = map_util_freq(util, freq, max);

	if (freq == dyn_policy->cached_raw_freq && !dyn_policy->need_freq_update)
		return dyn_policy->next_freq;

	dyn_policy->cached_raw_freq = freq;
	return cpufreq_driver_resolve_freq(policy, freq);
}

/************************ IO wait boost ***********************/

static bool dyn_iowait_reset(struct dynasched_cpu *dyn_cpu, u64 time,
			     bool set_iowait_boost)
{
	s64 delta_ns = time - dyn_cpu->last_update;

	if (delta_ns <= TICK_NSEC)
		return false;

	dyn_cpu->iowait_boost = set_iowait_boost ? IOWAIT_BOOST_MIN : 0;
	dyn_cpu->iowait_boost_pending = set_iowait_boost;
	return true;
}

static void dyn_iowait_boost(struct dynasched_cpu *dyn_cpu, u64 time,
			     unsigned int flags)
{
	bool set_iowait_boost = flags & SCHED_CPUFREQ_IOWAIT;

	if (dyn_cpu->iowait_boost &&
	    dyn_iowait_reset(dyn_cpu, time, set_iowait_boost))
		return;

	if (!set_iowait_boost)
		return;

	if (dyn_cpu->iowait_boost_pending)
		return;
	dyn_cpu->iowait_boost_pending = true;

	if (dyn_cpu->iowait_boost) {
		dyn_cpu->iowait_boost =
			min_t(unsigned int, dyn_cpu->iowait_boost << 1,
			      SCHED_CAPACITY_SCALE);
		return;
	}
	dyn_cpu->iowait_boost = IOWAIT_BOOST_MIN;
}

static void dyn_iowait_apply(struct dynasched_cpu *dyn_cpu, u64 time)
{
	unsigned long boost;

	if (!dyn_cpu->iowait_boost)
		return;

	if (dyn_iowait_reset(dyn_cpu, time, false))
		return;

	if (!dyn_cpu->iowait_boost_pending) {
		dyn_cpu->iowait_boost >>= 1;
		if (dyn_cpu->iowait_boost < IOWAIT_BOOST_MIN) {
			dyn_cpu->iowait_boost = 0;
			return;
		}
	}
	dyn_cpu->iowait_boost_pending = false;

	boost = (dyn_cpu->iowait_boost * dyn_cpu->max) >> SCHED_CAPACITY_SHIFT;
	boost = uclamp_rq_util_with(cpu_rq(dyn_cpu->cpu), boost, NULL);
	if (dyn_cpu->util < boost)
		dyn_cpu->util = boost;
}

#ifdef CONFIG_NO_HZ_COMMON
static bool dyn_cpu_is_busy(struct dynasched_cpu *dyn_cpu)
{
	unsigned long idle_calls = tick_nohz_get_idle_calls_cpu(dyn_cpu->cpu);
	bool ret = idle_calls == dyn_cpu->saved_idle_calls;

	dyn_cpu->saved_idle_calls = idle_calls;
	return ret;
}
#else
static inline bool dyn_cpu_is_busy(struct dynasched_cpu *dyn_cpu)
{
	return false;
}
#endif

static inline void dyn_ignore_dl_rate_limit(struct dynasched_cpu *dyn_cpu)
{
	if (cpu_bw_dl(cpu_rq(dyn_cpu->cpu)) > dyn_cpu->bw_dl)
		WRITE_ONCE(dyn_cpu->dyn_policy->limits_changed, true);
}

/************************ Update callbacks ***********************/

static void dyn_update_single_freq(struct update_util_data *hook, u64 time,
				   unsigned int flags)
{
	struct dynasched_cpu *dyn_cpu =
		container_of(hook, struct dynasched_cpu, update_util);
	struct dynasched_policy *dyn_policy = dyn_cpu->dyn_policy;
	unsigned int cached_freq = dyn_policy->cached_raw_freq;
	unsigned long util;
	unsigned int next_f;

	dyn_iowait_boost(dyn_cpu, time, flags);
	dyn_cpu->last_update = time;
	dyn_ignore_dl_rate_limit(dyn_cpu);

	dyn_get_util(dyn_cpu);
	dyn_iowait_apply(dyn_cpu, time);

	util = dyn_apply_headroom(dyn_cpu);
	next_f = dyn_get_next_freq(dyn_policy, util, dyn_cpu->max);

	if (!dyn_should_update_freq(dyn_policy, time, next_f))
		return;

	if (!uclamp_rq_is_capped(cpu_rq(dyn_cpu->cpu)) &&
	    dyn_cpu_is_busy(dyn_cpu) && next_f < dyn_policy->next_freq &&
	    !dyn_policy->need_freq_update) {
		next_f = dyn_policy->next_freq;
		dyn_policy->cached_raw_freq = cached_freq;
	}

	if (!dyn_update_next_freq(dyn_policy, time, next_f))
		return;

	if (dyn_policy->policy->fast_switch_enabled)
		cpufreq_driver_fast_switch(dyn_policy->policy, next_f);
	else {
		raw_spin_lock(&dyn_policy->update_lock);
		dyn_deferred_update(dyn_policy);
		raw_spin_unlock(&dyn_policy->update_lock);
	}
}

static unsigned int dyn_next_freq_shared(struct dynasched_cpu *dyn_cpu,
					 u64 time)
{
	struct dynasched_policy *dyn_policy = dyn_cpu->dyn_policy;
	struct cpufreq_policy *policy = dyn_policy->policy;
	unsigned long util = 0, max = 1;
	unsigned int j;

	for_each_cpu(j, policy->cpus) {
		struct dynasched_cpu *j_cpu = &per_cpu(dynasched_cpu, j);
		unsigned long j_util, j_max;

		dyn_get_util(j_cpu);
		dyn_iowait_apply(j_cpu, time);
		j_util = dyn_apply_headroom(j_cpu);
		j_max  = j_cpu->max;

		if (j_util * max > j_max * util) {
			util = j_util;
			max  = j_max;
		}
	}

	return dyn_get_next_freq(dyn_policy, util, max);
}

static void dyn_update_shared(struct update_util_data *hook, u64 time,
			      unsigned int flags)
{
	struct dynasched_cpu *dyn_cpu =
		container_of(hook, struct dynasched_cpu, update_util);
	struct dynasched_policy *dyn_policy = dyn_cpu->dyn_policy;
	unsigned int next_f;

	raw_spin_lock(&dyn_policy->update_lock);

	dyn_iowait_boost(dyn_cpu, time, flags);
	dyn_cpu->last_update = time;
	dyn_ignore_dl_rate_limit(dyn_cpu);

	next_f = dyn_next_freq_shared(dyn_cpu, time);

	if (!dyn_should_update_freq(dyn_policy, time, next_f))
		goto unlock;

	if (!dyn_update_next_freq(dyn_policy, time, next_f))
		goto unlock;

	if (dyn_policy->policy->fast_switch_enabled)
		cpufreq_driver_fast_switch(dyn_policy->policy, next_f);
	else
		dyn_deferred_update(dyn_policy);

unlock:
	raw_spin_unlock(&dyn_policy->update_lock);
}

/************************ kthread work ***********************/

static void dyn_work(struct kthread_work *work)
{
	struct dynasched_policy *dyn_policy =
		container_of(work, struct dynasched_policy, work);
	unsigned int freq;
	unsigned long flags;

	raw_spin_lock_irqsave(&dyn_policy->update_lock, flags);
	freq = dyn_policy->next_freq;
	dyn_policy->work_in_progress = false;
	raw_spin_unlock_irqrestore(&dyn_policy->update_lock, flags);

	mutex_lock(&dyn_policy->work_lock);
	__cpufreq_driver_target(dyn_policy->policy, freq, CPUFREQ_RELATION_L);
	mutex_unlock(&dyn_policy->work_lock);
}

static void dyn_irq_work(struct irq_work *irq_work)
{
	struct dynasched_policy *dyn_policy =
		container_of(irq_work, struct dynasched_policy, irq_work);

	kthread_queue_work(&dyn_policy->worker, &dyn_policy->work);
}

/************************ sysfs interface ***********************/

static inline struct dynasched_tunables *
to_dyn_tunables(struct gov_attr_set *attr_set)
{
	return container_of(attr_set, struct dynasched_tunables, attr_set);
}

/* bias */
static ssize_t bias_show(struct gov_attr_set *attr_set, char *buf)
{
	struct dynasched_tunables *t = to_dyn_tunables(attr_set);
	const char *s;

	switch (t->bias) {
	case DYN_BIAS_PERFORMANCE: s = "performance"; break;
	case DYN_BIAS_BATTERY:     s = "battery";     break;
	default:                   s = "balanced";     break;
	}
	return sprintf(buf, "%s\n", s);
}

static ssize_t bias_store(struct gov_attr_set *attr_set, const char *buf,
			  size_t count)
{
	struct dynasched_tunables *t = to_dyn_tunables(attr_set);
	struct dynasched_policy *dp;

	if (sysfs_streq(buf, "performance"))
		t->bias = DYN_BIAS_PERFORMANCE;
	else if (sysfs_streq(buf, "battery"))
		t->bias = DYN_BIAS_BATTERY;
	else if (sysfs_streq(buf, "balanced"))
		t->bias = DYN_BIAS_BALANCED;
	else
		return -EINVAL;

	dyn_apply_bias(t);

	/* propagate new rate limits to all policies sharing these tunables */
	list_for_each_entry(dp, &attr_set->policy_list, tunables_hook) {
		/* nothing extra needed; rate limits read directly from tunables */
		(void)dp;
	}

	return count;
}

/* up_rate_limit_us */
static ssize_t up_rate_limit_us_show(struct gov_attr_set *attr_set, char *buf)
{
	struct dynasched_tunables *t = to_dyn_tunables(attr_set);

	return sprintf(buf, "%lld\n", div_s64(t->up_rate_limit_ns, NSEC_PER_USEC));
}

static ssize_t up_rate_limit_us_store(struct gov_attr_set *attr_set,
				      const char *buf, size_t count)
{
	struct dynasched_tunables *t = to_dyn_tunables(attr_set);
	unsigned int val;

	if (kstrtouint(buf, 10, &val))
		return -EINVAL;
	t->up_rate_limit_ns = val * NSEC_PER_USEC;
	return count;
}

/* down_rate_limit_us */
static ssize_t down_rate_limit_us_show(struct gov_attr_set *attr_set, char *buf)
{
	struct dynasched_tunables *t = to_dyn_tunables(attr_set);

	return sprintf(buf, "%lld\n", div_s64(t->down_rate_limit_ns, NSEC_PER_USEC));
}

static ssize_t down_rate_limit_us_store(struct gov_attr_set *attr_set,
					const char *buf, size_t count)
{
	struct dynasched_tunables *t = to_dyn_tunables(attr_set);
	unsigned int val;

	if (kstrtouint(buf, 10, &val))
		return -EINVAL;
	t->down_rate_limit_ns = val * NSEC_PER_USEC;
	return count;
}

/* headroom */
static ssize_t headroom_show(struct gov_attr_set *attr_set, char *buf)
{
	return sprintf(buf, "%u\n", to_dyn_tunables(attr_set)->headroom);
}

static ssize_t headroom_store(struct gov_attr_set *attr_set, const char *buf,
			      size_t count)
{
	unsigned int val;

	if (kstrtouint(buf, 10, &val) || val == 0 || val > 512)
		return -EINVAL;
	to_dyn_tunables(attr_set)->headroom = val;
	return count;
}

static struct governor_attr bias            = __ATTR_RW(bias);
static struct governor_attr up_rate_limit_us   = __ATTR_RW(up_rate_limit_us);
static struct governor_attr down_rate_limit_us = __ATTR_RW(down_rate_limit_us);
static struct governor_attr headroom        = __ATTR_RW(headroom);

static struct attribute *dynasched_attrs[] = {
	&bias.attr,
	&up_rate_limit_us.attr,
	&down_rate_limit_us.attr,
	&headroom.attr,
	NULL
};
ATTRIBUTE_GROUPS(dynasched);

static void dynasched_tunables_free(struct kobject *kobj)
{
	kfree(to_dyn_tunables(to_gov_attr_set(kobj)));
}

static struct kobj_type dynasched_tunables_ktype = {
	.default_groups = dynasched_groups,
	.sysfs_ops      = &governor_sysfs_ops,
	.release        = &dynasched_tunables_free,
};

/************************ cpufreq governor interface ***********************/

struct cpufreq_governor dynasched_gov;

static struct dynasched_policy *dyn_policy_alloc(struct cpufreq_policy *policy)
{
	struct dynasched_policy *dyn_policy;

	dyn_policy = kzalloc(sizeof(*dyn_policy), GFP_KERNEL);
	if (!dyn_policy)
		return NULL;

	dyn_policy->policy = policy;
	raw_spin_lock_init(&dyn_policy->update_lock);
	return dyn_policy;
}

static int dyn_kthread_create(struct dynasched_policy *dyn_policy)
{
	struct task_struct *thread;
	struct sched_attr attr = {
		.size           = sizeof(struct sched_attr),
		.sched_policy   = SCHED_DEADLINE,
		.sched_flags    = SCHED_FLAG_SUGOV,
		.sched_nice     = 0,
		.sched_priority = 0,
		.sched_runtime  =  1000000,
		.sched_deadline = 10000000,
		.sched_period   = 10000000,
	};
	struct cpufreq_policy *policy = dyn_policy->policy;
	int ret;

	if (policy->fast_switch_enabled)
		return 0;

	trace_android_vh_set_sugov_sched_attr(&attr);
	kthread_init_work(&dyn_policy->work, dyn_work);
	kthread_init_worker(&dyn_policy->worker);
	thread = kthread_create(kthread_worker_fn, &dyn_policy->worker,
				"dynasched:%d",
				cpumask_first(policy->related_cpus));
	if (IS_ERR(thread))
		return PTR_ERR(thread);

	ret = sched_setattr_nocheck(thread, &attr);
	if (ret) {
		kthread_stop(thread);
		return ret;
	}

	dyn_policy->thread = thread;
	kthread_bind_mask(thread, policy->related_cpus);
	init_irq_work(&dyn_policy->irq_work, dyn_irq_work);
	mutex_init(&dyn_policy->work_lock);
	wake_up_process(thread);
	return 0;
}

static void dyn_kthread_stop(struct dynasched_policy *dyn_policy)
{
	if (dyn_policy->policy->fast_switch_enabled)
		return;

	kthread_flush_worker(&dyn_policy->worker);
	kthread_stop(dyn_policy->thread);
	mutex_destroy(&dyn_policy->work_lock);
}

static int dynasched_init(struct cpufreq_policy *policy)
{
	struct dynasched_policy *dyn_policy;
	struct dynasched_tunables *tunables;
	int ret = 0;

	if (policy->governor_data)
		return -EBUSY;

	cpufreq_enable_fast_switch(policy);

	dyn_policy = dyn_policy_alloc(policy);
	if (!dyn_policy) {
		ret = -ENOMEM;
		goto disable_fast_switch;
	}

	ret = dyn_kthread_create(dyn_policy);
	if (ret)
		goto free_policy;

	mutex_lock(&global_tunables_lock);

	if (global_tunables) {
		if (WARN_ON(have_governor_per_policy())) {
			ret = -EINVAL;
			goto stop_kthread;
		}
		policy->governor_data = dyn_policy;
		dyn_policy->tunables = global_tunables;
		gov_attr_set_get(&global_tunables->attr_set,
				 &dyn_policy->tunables_hook);
		goto out;
	}

	tunables = kzalloc(sizeof(*tunables), GFP_KERNEL);
	if (!tunables) {
		ret = -ENOMEM;
		goto stop_kthread;
	}

	tunables->cluster = dyn_detect_cluster(policy);
	tunables->bias    = DYN_BIAS_BALANCED;
	dyn_apply_bias(tunables);

	gov_attr_set_init(&tunables->attr_set, &dyn_policy->tunables_hook);
	if (!have_governor_per_policy())
		global_tunables = tunables;

	policy->governor_data = dyn_policy;
	dyn_policy->tunables  = tunables;

	ret = kobject_init_and_add(&tunables->attr_set.kobj,
				   &dynasched_tunables_ktype,
				   get_governor_parent_kobj(policy),
				   "%s", dynasched_gov.name);
	if (ret)
		goto fail;

out:
	mutex_unlock(&global_tunables_lock);
	return 0;

fail:
	kobject_put(&tunables->attr_set.kobj);
	policy->governor_data = NULL;
	if (!have_governor_per_policy())
		global_tunables = NULL;
stop_kthread:
	dyn_kthread_stop(dyn_policy);
	mutex_unlock(&global_tunables_lock);
free_policy:
	kfree(dyn_policy);
disable_fast_switch:
	cpufreq_disable_fast_switch(policy);
	pr_err("dynasched: initialization failed (%d)\n", ret);
	return ret;
}

static void dynasched_exit(struct cpufreq_policy *policy)
{
	struct dynasched_policy *dyn_policy = policy->governor_data;
	struct dynasched_tunables *tunables = dyn_policy->tunables;
	unsigned int count;

	mutex_lock(&global_tunables_lock);
	count = gov_attr_set_put(&tunables->attr_set, &dyn_policy->tunables_hook);
	policy->governor_data = NULL;
	if (!count && !have_governor_per_policy())
		global_tunables = NULL;
	mutex_unlock(&global_tunables_lock);

	dyn_kthread_stop(dyn_policy);
	kfree(dyn_policy);
	cpufreq_disable_fast_switch(policy);
}

static int dynasched_start(struct cpufreq_policy *policy)
{
	struct dynasched_policy *dyn_policy = policy->governor_data;
	unsigned int cpu;

	dyn_policy->last_freq_update_time = 0;
	dyn_policy->last_up_time          = 0;
	dyn_policy->last_down_time        = 0;
	dyn_policy->next_freq             = 0;
	dyn_policy->work_in_progress      = false;
	dyn_policy->limits_changed        = false;
	dyn_policy->cached_raw_freq       = 0;
	dyn_policy->need_freq_update =
		cpufreq_driver_test_flags(CPUFREQ_NEED_UPDATE_LIMITS);

	for_each_cpu(cpu, policy->cpus) {
		struct dynasched_cpu *dyn_cpu = &per_cpu(dynasched_cpu, cpu);

		memset(dyn_cpu, 0, sizeof(*dyn_cpu));
		dyn_cpu->cpu        = cpu;
		dyn_cpu->dyn_policy = dyn_policy;
	}

	for_each_cpu(cpu, policy->cpus) {
		struct dynasched_cpu *dyn_cpu = &per_cpu(dynasched_cpu, cpu);
		void (*uu)(struct update_util_data *, u64, unsigned int);

		uu = policy_is_shared(policy) ?
		     dyn_update_shared : dyn_update_single_freq;
		cpufreq_add_update_util_hook(cpu, &dyn_cpu->update_util, uu);
	}
	return 0;
}

static void dynasched_stop(struct cpufreq_policy *policy)
{
	struct dynasched_policy *dyn_policy = policy->governor_data;
	unsigned int cpu;

	for_each_cpu(cpu, policy->cpus)
		cpufreq_remove_update_util_hook(cpu);

	synchronize_rcu();

	if (!policy->fast_switch_enabled) {
		irq_work_sync(&dyn_policy->irq_work);
		kthread_cancel_work_sync(&dyn_policy->work);
	}
}

static void dynasched_limits(struct cpufreq_policy *policy)
{
	struct dynasched_policy *dyn_policy = policy->governor_data;

	if (!policy->fast_switch_enabled) {
		mutex_lock(&dyn_policy->work_lock);
		cpufreq_policy_apply_limits(policy);
		mutex_unlock(&dyn_policy->work_lock);
	}

	smp_wmb();
	WRITE_ONCE(dyn_policy->limits_changed, true);
}

struct cpufreq_governor dynasched_gov = {
	.name   = "dynasched",
	.owner  = THIS_MODULE,
	.flags  = CPUFREQ_GOV_DYNAMIC_SWITCHING,
	.init   = dynasched_init,
	.exit   = dynasched_exit,
	.start  = dynasched_start,
	.stop   = dynasched_stop,
	.limits = dynasched_limits,
};

#ifdef CONFIG_CPU_FREQ_DEFAULT_GOV_DYNASCHED
struct cpufreq_governor *cpufreq_default_governor(void)
{
	return &dynasched_gov;
}
#endif

cpufreq_governor_init(dynasched_gov);
