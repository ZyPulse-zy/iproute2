#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

. lib/generic.sh

# The testsuite normally supplies IP and runs each test under unshare -n.
[ -n "$IP" ] || ts_skip
if [ -n "$IPROUTE_TEST_PARENT_NETNS" ] &&
   [ "$(readlink /proc/self/ns/net)" = "$IPROUTE_TEST_PARENT_NETNS" ]; then
	ts_err "Refusing route writes in the parent network namespace"
	exit 1
fi

ts_log "[Testing route flush with nexthop objects and compatibility attributes]"
DEV=nhflush0
ts_ip "$0" "Bring namespace loopback up" link set lo up
ts_ip "$0" "Create private dummy device" link add "$DEV" type dummy
ts_ip "$0" "Bring device up" link set "$DEV" up

for family in 4 6; do
	if [ "$family" = 4 ]; then
		addr=192.0.2.2/24
		gw=192.0.2.1
		gw2=192.0.2.3
		prefix=203.0.113.0/24
		group_prefix=198.51.100.0/24
		plain_prefix=198.18.0.0/24
		nh=101
		nh2=102
		group=103
	else
		addr=2001:db8:1::2/64
		gw=2001:db8:1::1
		gw2=2001:db8:1::3
		prefix=2001:db8:2::/64
		group_prefix=2001:db8:3::/64
		plain_prefix=2001:db8:4::/64
		nh=201
		nh2=202
		group=203
	fi
	if [ "$family" = 6 ]; then
		ts_ip "$0" "Assign IPv6 address" -6 addr add "$addr" dev "$DEV" nodad
	else
		ts_ip "$0" "Assign IPv4 address" -4 addr add "$addr" dev "$DEV"
	fi
	ts_ip "$0" "Create first nexthop" -"$family" nexthop add id "$nh" via "$gw" dev "$DEV" onlink
	ts_ip "$0" "Create second nexthop" -"$family" nexthop add id "$nh2" via "$gw2" dev "$DEV"
	ts_ip "$0" "Create nexthop group" nexthop add id "$group" group "$nh/$nh2"
	ts_ip "$0" "Add selected single-nexthop route" -"$family" route add table 111 "$prefix" nhid "$nh" metric 10 mtu 1400 advmss 1360
	ts_ip "$0" "Add another metric on same prefix" -"$family" route add table 111 "$prefix" nhid "$nh2" metric 20
	ts_ip "$0" "Add same route in another table" -"$family" route add table 112 "$prefix" nhid "$nh" metric 10
	ts_ip "$0" "Flush selected metric only" -"$family" route flush table 111 metric 10
	ts_ip "$0" "Check other metric survived" -"$family" route show table 111 "$prefix"
	test_on "nhid $nh2"
	test_on "metric 20"
	test_lines_count 1
	ts_ip "$0" "Check other table survived" -"$family" route show table 112 "$prefix"
	test_on "nhid $nh"
	test_lines_count 1
	ts_ip "$0" "Add multipath nexthop-object route" -"$family" route add table 111 "$group_prefix" nhid "$group" metric 30
	ts_ip "$0" "Flush group with verbose display of original dump" -"$family" -s -s route flush table 111 to "$group_prefix"
	test_on "nhid $group"
	ts_ip "$0" "Check group route was removed" -"$family" route show table 111 "$group_prefix"
	test_lines_count 0
	ts_ip "$0" "Check nexthop group itself survived" nexthop show id "$group"
	test_on "id $group group"
	ts_ip "$0" "Add ordinary multipath route without ID" -"$family" route add table 111 "$plain_prefix" nexthop via "$gw" dev "$DEV" weight 1 nexthop via "$gw2" dev "$DEV" weight 2
	ts_ip "$0" "Flush ordinary multipath route" -"$family" route flush table 111 to "$plain_prefix"
	ts_ip "$0" "Check ordinary route removed" -"$family" route show table 111 "$plain_prefix"
	test_lines_count 0
	# One flush batch mixes compacted single/group messages with an unchanged
	# ordinary route. The next message must start at the new compacted length.
	ts_ip "$0" "Add group to mixed flush batch" -"$family" route add table 111 "$group_prefix" nhid "$group" metric 30
	ts_ip "$0" "Add ordinary route to mixed flush batch" -"$family" route add table 111 "$plain_prefix" dev "$DEV" metric 40
	ts_ip "$0" "Flush mixed batch with original dump display" -"$family" -s -s route flush table 111
	test_on "nhid $nh2"
	test_on "nhid $group"
	ts_ip "$0" "Check no selected routes remain" -"$family" route show table 111
	test_lines_count 0
	ts_ip "$0" "Flush second table" -"$family" route flush table 112
done

# A blackhole object has no compatibility gateway/device fields to strip.
ts_ip "$0" "Create IPv4 blackhole nexthop" -4 nexthop add id 301 blackhole
ts_ip "$0" "Add blackhole-object route" -4 route add table 111 192.0.2.0/24 nhid 301
ts_ip "$0" "Flush ID-only blackhole route" -4 route flush table 111
ts_ip "$0" "Check blackhole object retained" nexthop show id 301
test_on "id 301 blackhole"
for type in blackhole unreachable prohibit; do
	ts_ip "$0" "Add $type alias using blackhole object" -4 route add "$type" 192.0.2.0/24 table 111 nhid 301
	ts_ip "$0" "Flush $type alias without relying on synthesized dump type" -4 route flush table 111
	ts_ip "$0" "Check $type alias removed" -4 route show table 111
	test_lines_count 0
done
ts_ip "$0" "Create IPv6 blackhole nexthop" -6 nexthop add id 302 blackhole
ts_ip "$0" "Add IPv6 blackhole-object route" -6 route add table 111 2001:db8:5::/64 nhid 302
ts_ip "$0" "Flush IPv6 ID-only blackhole route" -6 route flush table 111
ts_ip "$0" "Check IPv6 blackhole object retained" nexthop show id 302
test_on "id 302 blackhole"
ts_ip "$0" "Add ordinary blackhole route without ID" -4 route add blackhole 192.0.2.0/24 table 111
ts_ip "$0" "Flush ordinary blackhole route" -4 route flush table 111
ts_ip "$0" "Check ordinary blackhole route removed" -4 route show table 111
test_lines_count 0

# Type filtering must not delete another alias sharing the prefix, metric and ID.
ts_ip "$0" "Add unicast type-filter sentinel" -4 route add 203.0.113.0/24 table 111 nhid 101 metric 50
ts_ip "$0" "Append explicit blackhole alias with same nexthop" -4 route append blackhole 203.0.113.0/24 table 111 nhid 101 metric 50
ts_ip "$0" "Flush only explicit blackhole type" -4 route flush table 111 type blackhole
ts_ip "$0" "Check unicast alias survived type filtering" -4 route show table 111
test_on "nhid 101"
test_lines_count 1
ts_ip "$0" "Delete remaining unicast sentinel by exact type" -4 route del unicast 203.0.113.0/24 table 111 nhid 101 metric 50

# A blackhole object hides the original IPv4 alias type in dumps. An explicit
# type request must fail conservatively, rather than delete the unicast alias.
ts_ip "$0" "Add alias with synthesized dump type" -4 route add 192.0.2.0/24 table 111 nhid 301
if $IP -4 route flush table 111 type blackhole > "$STD_OUT" 2> "$STD_ERR"; then
	ts_err "Ambiguous blackhole-object type filter unexpectedly succeeded"
else
	ts_log "Ambiguous explicit type failed conservatively:"
	ts_cat "$STD_ERR"
fi
ts_ip "$0" "Check ambiguous unicast alias retained" -4 route show table 111
test_lines_count 1
ts_ip "$0" "Delete retained alias by its actual unicast type" -4 route del unicast 192.0.2.0/24 table 111 nhid 301

# IPv4 via an IPv6 nexthop expands to RTA_VIA rather than RTA_GATEWAY.
ts_ip "$0" "Add cross-family nexthop route" -4 route add table 111 203.0.113.0/24 nhid 201
ts_ip "$0" "Flush cross-family route" -4 route flush table 111
ts_ip "$0" "Check cross-family route removed" -4 route show table 111
test_lines_count 0

ts_ip "$0" "Delete test device and its nexthops" link del "$DEV"
ts_ip "$0" "Delete blackhole nexthop" nexthop del id 301
ts_ip "$0" "Delete IPv6 blackhole nexthop" nexthop del id 302
