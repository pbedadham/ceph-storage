# Check Ceph status
ssh root@server1 "ceph -s"

# Check OSDs
ssh root@server1 "ceph osd tree"

# Check health
ssh root@server1 "ceph health"

# Check if services are running
for server in server1 server2 server3; do
  echo "=== $server ==="
  ssh root@$server "ps aux | grep ceph | grep -v grep"
done