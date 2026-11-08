Draft by Claude (2026-11-08), not reviewed yet.

Check the other end: the router/switch port's spec (many ISP routers have
Fast Ethernet ports), or plug the server into another port or a known
gigabit switch, then:

  ethtool eno25 | grep -E 'Speed|Duplex'
