// UnifiedSession.join_code when hosting direct: the address a friend types into join_direct, from this machine's
// network interfaces (session thread, once per host_direct).
package godot

import "core:fmt"
import "core:net"

// `host:port`: this machine's private IPv4 address a friend on the same network reaches (192.168/16 first, then 10/8,
// then 172.16/12, where virtual adapters usually sit; the lowest of a range), or 127.0.0.1 when it has none or the
// host listens on loopback only (`local`, tool runs).
@(private)
direct_join_code :: proc(port: int, local: bool) -> string {
	best: net.IP4_Address
	best_rank := 0
	if !local {
		interfaces, err := net.enumerate_interfaces(context.temp_allocator)
		if err == nil {
			for &interface in interfaces {
				for lease in interface.unicast {
					address, is_ip4 := lease.address.(net.IP4_Address)
					if !is_ip4 do continue
					rank := private_rank(address)
					if rank > best_rank || (rank == best_rank && rank > 0 && ip4_less(address, best)) {
						best, best_rank = address, rank
					}
				}
			}
		}
	}
	if best_rank == 0 do best = {127, 0, 0, 1}
	return fmt.tprintf("%d.%d.%d.%d:%d", best[0], best[1], best[2], best[3], port)
}

// How likely a private address is the one a friend reaches (0: not private).
@(private = "file")
private_rank :: proc(address: net.IP4_Address) -> int {
	switch {
	case address[0] == 192 && address[1] == 168:
		return 3
	case address[0] == 10:
		return 2
	case address[0] == 172 && address[1] >= 16 && address[1] < 32:
		return 1
	}
	return 0
}

@(private = "file")
ip4_less :: proc(a, b: net.IP4_Address) -> bool {
	for i in 0 ..< 4 do if a[i] != b[i] do return a[i] < b[i]
	return false
}
