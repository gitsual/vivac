#!/usr/bin/env bash
set -Eeuo pipefail

# Turn the sealed qcow2 into what a release actually carries: the same disk as
# an OVA for VirtualBox and VMware, both cut into pieces GitHub will accept,
# and checksums for every piece and for each whole file.
#
# The ceiling is not advisory: a release asset over it is refused at upload,
# after a very long upload. The budget is checked here instead.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
dist="$repo_root/dist"
image="$dist/vivac.qcow2"
# GitHub refuses a release asset over 2 GiB; the slack absorbs nothing, it is
# simply a round number below the wall.
part_size="${VM_IMAGE_PART_SIZE:-1900M}"
ceiling=$((2 * 1024 * 1024 * 1024))
memory_mb="${VM_IMAGE_OVA_MEMORY:-4096}"
cpus="${VM_IMAGE_OVA_CPUS:-2}"

usage() {
	cat <<'USAGE'
Usage: scripts/package-vm-image.sh [--image PATH]

Package the sealed image as release assets: an OVA beside the qcow2, both
split under the 2 GiB asset ceiling, with SHA256SUMS over parts and wholes.
Overrides: VM_IMAGE_PART_SIZE, VM_IMAGE_OVA_MEMORY, VM_IMAGE_OVA_CPUS.
USAGE
}

while (($#)); do
	case "$1" in
	--image)
		[[ $# -ge 2 ]] || {
			printf '%s\n' '--image needs a path' >&2
			exit 2
		}
		image="$2"
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'Unknown option: %s\n' "$1" >&2
		exit 2
		;;
	esac
	shift
done

for command_name in qemu-img tar split sha256sum stat numfmt; do
	command -v "$command_name" >/dev/null || {
		printf 'Missing host dependency: %s\n' "$command_name" >&2
		exit 1
	}
done
[[ -f "$image" ]] || {
	printf 'No sealed image at %s; run scripts/build-vm-image.sh first\n' "$image" >&2
	exit 1
}

dist="$(dirname -- "$image")"
stem="$(basename -- "${image%.qcow2}")"
rm -f -- "$dist/$stem".qcow2.part* "$dist/$stem".ova "$dist/$stem".ova.part* "$dist/$stem.vmdk" "$dist/$stem.ovf" "$dist/SHA256SUMS"

capacity="$(qemu-img info --output=json "$image" | python -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])')"

printf '%s\n' 'Converting to streamOptimized VMDK...'
qemu-img convert -O vmdk -o subformat=streamOptimized "$image" "$dist/$stem.vmdk"
vmdk_bytes="$(stat -c %s "$dist/$stem.vmdk")"

# Minimal OVF 1.0: one disk, one NIC, enough for VirtualBox and VMware to
# import without hand-editing. The disk capacity must match the qcow2's
# virtual size or the import refuses the descriptor.
cat >"$dist/$stem.ovf" <<OVF
<?xml version="1.0" encoding="UTF-8"?>
<Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1" xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1" xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData" xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <References>
    <File ovf:href="$stem.vmdk" ovf:id="file1" ovf:size="$vmdk_bytes"/>
  </References>
  <DiskSection>
    <Info>Virtual disk information</Info>
    <Disk ovf:capacity="$capacity" ovf:diskId="vmdisk1" ovf:fileRef="file1" ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/>
  </DiskSection>
  <NetworkSection>
    <Info>The list of logical networks</Info>
    <Network ovf:name="NAT">
      <Description>NAT network</Description>
    </Network>
  </NetworkSection>
  <VirtualSystem ovf:id="vivac">
    <Info>An Arch Linux workstation provisioned by vivac</Info>
    <Name>vivac</Name>
    <OperatingSystemSection ovf:id="101">
      <Info>The kind of installed guest operating system</Info>
      <Description>Arch Linux (64-bit)</Description>
    </OperatingSystemSection>
    <VirtualHardwareSection>
      <Info>Virtual hardware requirements</Info>
      <System>
        <vssd:ElementName>Virtual Hardware Family</vssd:ElementName>
        <vssd:InstanceID>0</vssd:InstanceID>
        <vssd:VirtualSystemType>virtualbox-2.2</vssd:VirtualSystemType>
      </System>
      <Item>
        <rasd:Description>Number of virtual CPUs</rasd:Description>
        <rasd:ElementName>$cpus virtual CPU</rasd:ElementName>
        <rasd:InstanceID>1</rasd:InstanceID>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:VirtualQuantity>$cpus</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits>
        <rasd:Description>Memory Size</rasd:Description>
        <rasd:ElementName>$memory_mb MB of memory</rasd:ElementName>
        <rasd:InstanceID>2</rasd:InstanceID>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>$memory_mb</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:Address>0</rasd:Address>
        <rasd:Description>SCSI Controller</rasd:Description>
        <rasd:ElementName>scsiController0</rasd:ElementName>
        <rasd:InstanceID>3</rasd:InstanceID>
        <rasd:ResourceSubType>VirtioSCSI</rasd:ResourceSubType>
        <rasd:ResourceType>20</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AddressOnParent>0</rasd:AddressOnParent>
        <rasd:ElementName>disk1</rasd:ElementName>
        <rasd:HostResource>/disk/vmdisk1</rasd:HostResource>
        <rasd:InstanceID>4</rasd:InstanceID>
        <rasd:Parent>3</rasd:Parent>
        <rasd:ResourceType>17</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AutomaticAllocation>true</rasd:AutomaticAllocation>
        <rasd:Connection>NAT</rasd:Connection>
        <rasd:ElementName>Ethernet adapter on 'NAT'</rasd:ElementName>
        <rasd:InstanceID>5</rasd:InstanceID>
        <rasd:ResourceType>10</rasd:ResourceType>
      </Item>
    </VirtualHardwareSection>
  </VirtualSystem>
</Envelope>
OVF

# The descriptor must be the first entry of the archive, per the OVF spec.
printf '%s\n' 'Assembling the OVA...'
tar -C "$dist" -cf "$dist/$stem.ova" "$stem.ovf" "$stem.vmdk"
rm -f -- "$dist/$stem.vmdk" "$dist/$stem.ovf"

cd "$dist"
sums=()
for artifact in "$stem.qcow2" "$stem.ova"; do
	bytes="$(stat -c %s "$artifact")"
	printf '%-34s %s\n' "$artifact" "$(numfmt --to=iec --suffix=B "$bytes")"
	sums+=("$artifact")
	if ((bytes > ceiling)); then
		split -b "$part_size" -d -a 2 -- "$artifact" "$artifact.part"
		for part in "$artifact".part*; do
			part_bytes="$(stat -c %s "$part")"
			((part_bytes <= ceiling)) || {
				printf '%s is %s, over the %s release asset ceiling\n' \
					"$part" "$(numfmt --to=iec --suffix=B "$part_bytes")" \
					"$(numfmt --to=iec --suffix=B "$ceiling")" >&2
				exit 1
			}
			printf '  %-32s %s\n' "$part" "$(numfmt --to=iec --suffix=B "$part_bytes")"
			sums+=("$part")
		done
	fi
done

sha256sum -- "${sums[@]}" >SHA256SUMS
printf 'Packaged %d files into %s/SHA256SUMS\n' "${#sums[@]}" "$dist"
