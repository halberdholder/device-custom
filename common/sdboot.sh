#!/bin/bash -e

# 需要注意的几点：
# 1. 要保证ddr bin中有初始化对应的uart调试串口， 许多芯片的uart调试串口是跟sdcard的pin冲突。 ddr bin 中如果碰到从sdcard启动，并且sdcard与uart有冲突， 可能会关闭uart，这样无法继续调试。
# 2. 需要保证硬件上， sdcard的上电不依赖于软件， 如硬件上vcc sd要默认有
# 3. 要保证uboot image中有初始化sdcard， dts有使能。
# 4. 最好把emmc/nand中的固件擦除，虽然maskrom默认启动优先级是sdcard比较高， 但最好把emmc/nand先擦除
# 5. 如果由于loader不开源难调试，可以只在emmc中刷入loader， 然后其它固件放到uboot中， 这样emmc 中的loader也能加载sd card 中的固件。(仍然有前提是uart与sdcard不能冲突)

BOOT_MERGER=./u-boot/tools/boot_merger
MKIMAGE=./u-boot/tools/mkimage

#Array of parts with elem in format:
#   fmt1: "size@offset@label"
#   fmt2: "-@offset@label" that size is grew
PARTITIONS=
OFFSETS=
SIZES=
LABELS=

# Input:
#    $1: parameter
function parse_parameter
{
	local para="$(realpath $1)"

	local regex="[-0x]{,2}[[:xdigit:]]*@0x[[:xdigit:]]+\([[:alpha:]]+"
	PARTITIONS=($(egrep -o "${regex}" "${para}" | sed -r 's/\(/@/g'))

	for p in ${PARTITIONS[@]}; do
		l=$(echo $p | cut -d'@' -f1)
		SIZES=(${SIZES[@]} $l)

		l=$(echo $p | cut -d'@' -f2)
		OFFSETS=(${OFFSETS[@]} $l)

		l=$(echo $p | cut -d'@' -f3)
		LABELS=(${LABELS[@]} $l)
	done
}

# Input:
#   $1: MiniloaderAll.bin
#   $2: chip type
function pack_idbloader
{
	local loader="$(realpath $1)"
	local chip=$2

	BOOT_MERGER=$(realpath ${BOOT_MERGER})
	MKIMAGE=$(realpath ${MKIMAGE})

	local TEMP=$(mktemp -d)
	pushd ${TEMP}
	${BOOT_MERGER} --unpack "${loader}"
	${MKIMAGE} \
		-n ${chip} \
		-T rksd \
		-d ./FlashData \
		idbloader.bin

	cat ./FlashBoot >> idbloader.bin

	popd
	mv ${TEMP}/idbloader.bin ./rockdev/
	rm -rf ${TEMP}

	echo "$(realpath idbloader.bin)"
}

function createGPT
{
	echo "Creating GPT..."
	local DEVICE=$1
	local ROOTFS=

	umount ${DEVICE}* 2>/dev/null || true
	parted -s $DEVICE mklabel gpt
	for i in ${!LABELS[@]}; do
		local offset=${OFFSETS[$i]}
		local label=${LABELS[$i]}
		local size=${SIZES[$i]}
		echo "Create partition:$label at $offset with size $size"
		local end=
		if [ ${SIZES[$i]} = "-" ]; then
			end=$(fdisk -l $DEVICE | egrep -o "[[:digit:]]+ sectors" | cut -f1 -d' ')
			end=$(($end - 64)) #the last 33 sectors are for gpt table and header
		else
			end=$(($size + $offset))
		fi
		end=$((end - 1)) # [start,end], end is included
		parted -s $DEVICE mkpart $label $((${offset}))s $((${end}))s

		expr match "$label" "root" > /dev/null 2>&1 && ROOTFS=$(($i + 1))
	done

	partprobe
	sgdisk --partition-guid=${ROOTFS}:614e0000-0000-4b53-8000-1d28000054a9 $DEVICE
}

function downloadImages
{
	echo "Downloading images..."
	local DEVICE=$1

	dd if=rockdev/idbloader.bin of=$DEVICE seek=64 conv=nocreat
	dd if=rockdev/parameter.txt of=$DEVICE seek=$((0x2000)) conv=nocreat

	for i in ${!LABELS[@]}; do
		local label=${LABELS[$i]}
		local index=$(($i + 1))
		echo "Copy $label image to ${DEVICE}${index}"
		[ -f rockdev/${label}.img ] || (echo file not found, skipped && continue)
		dd if=rockdev/${label}.img of=${DEVICE}${index} bs=1M conv=nocreat
	done

	sync && sync
}

[ $(id -u) -ne 0 ] && \
	echo "Run script as root" && exit
[ ! -f $BOOT_MERGER -o ! -f $MKIMAGE ] && \
	echo "Run script in Linux SDK top dir!!!" && exit

parse_parameter ./rockdev/parameter.txt

# pack_idbloader ./rockdev/MiniLoaderAll.bin $2
pack_idbloader ./rockdev/MiniLoaderAll.bin rk3399

createGPT $1

downloadImages $1

echo "Done!"
