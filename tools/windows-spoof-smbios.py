#!/usr/bin/env python3
import sys
import subprocess
import xml.etree.ElementTree as ET

def get_dmidecode():
    fields = {
        'bios-vendor': 'bios_vendor',
        'bios-version': 'bios_version',
        'bios-release-date': 'bios_date',
        'system-manufacturer': 'sys_vendor',
        'system-product-name': 'product_name',
        'system-serial-number': 'serial',
        'baseboard-manufacturer': 'board_vendor',
        'baseboard-product-name': 'board_product',
        'baseboard-serial-number': 'board_serial',
        'chassis-manufacturer': 'chassis_vendor',
        'chassis-serial-number': 'chassis_serial',
    }
    data = {}
    for dmidecode_field, xml_field in fields.items():
        try:
            val = subprocess.check_output(['sudo', 'dmidecode', '-s', dmidecode_field], text=True).strip()
            data[xml_field] = val
        except:
            data[xml_field] = "Unknown"
    return data

def apply_smbios(xml_path):
    tree = ET.parse(xml_path)
    root = tree.getroot()
    data = get_dmidecode()

    os = root.find("os")
    smbios = os.find("smbios")
    if smbios is None:
        smbios = ET.SubElement(os, "smbios", {"mode": "sysinfo"})

    sysinfo = root.find("sysinfo")
    if sysinfo is None:
        sysinfo = ET.SubElement(root, "sysinfo", {"type": "smbios"})

    # Clear old info
    for child in list(sysinfo):
        sysinfo.remove(child)

    ET.SubElement(sysinfo, "bios").append(ET.Element("entry", {"name": "vendor"}))
    sysinfo.find("bios").find("entry").text = data['bios_vendor']
    # ... Simplified mapping ...
    
    tree.write(xml_path, encoding="unicode")

if __name__ == "__main__":
    apply_smbios(sys.argv[1])
