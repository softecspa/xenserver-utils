#!/usr/bin/env python

try:
    import XenAPI
except ImportError as e:
    raise SystemExit('Import Error: %s' % e)

import sys

__version__ = (0, 0, 1)
__author__ = 'Lorenzo Cocchi <lorenzo.cocchi@softecspa.it>'


def humanize_bytes(bytes):
    """
    Keywords arguments:
        bytes -- size in bytes

    Returns: tuple
    """
    if bytes == 1:
        return '%s %s' % (float(1), 'B')

    suffixes_table = [
        ('B', 0), ('kiB', 0), ('MiB', 1), ('GiB', 2), ('TiB', 2),
        ('PiB', 2),
    ]

    num = float(bytes)
    for suffix, precision in suffixes_table:
        if num < 1024.0:
            break
        num /= 1024.0

    if precision == 0:
        formatted_size = '%d' % num
    else:
        formatted_size = str(round(num, ndigits=precision))

    return float(formatted_size), suffix


def get_all_vm(session):
    """
    Keywords arguments:
        session -- xenapi session object

    Returns: dict
    """

    return session.xenapi.VM.get_all()


def vm_filter(session, vm, power_state=None):
    if (session.xenapi.VM.get_is_control_domain(vm) is False and
            session.xenapi.VM.get_is_a_template(vm) is False and
            session.xenapi.VM.get_is_a_snapshot(vm) is False):

        if (power_state is not None and
                session.xenapi.VM.get_power_state(vm) == power_state):
            return vm

        if power_state is None:
            return vm


def get_vdi_from_vbd(session, vdb, vbd_type='Disk'):
    vdi_list = []
    vbd_record = session.xenapi.VBD.get_record(vdb)

    if vbd_record['type'] == vbd_type:

        vdi = vbd_record['VDI']
        vdivbds = session.xenapi.VDI.get_VBDs(vdi)
        vdisr = session.xenapi.VDI.get_SR(vdi)
        vdisize = session.xenapi.VDI.get_virtual_size(vdi)

        for vbd in vdivbds:
            vdivm = session.xenapi.VBD.get_VM(vbd)
            data = {
                'uuid': session.xenapi.VDI.get_uuid(vdi),
                'name': session.xenapi.VDI.get_name_label(vdi),
                'size': vdisize,
                'human_size': humanize_bytes(vdisize),
                'sr_uuid': session.xenapi.SR.get_uuid(vdisr),
                'sr_name': session.xenapi.SR.get_name_label(vdisr),
                'sr_type': session.xenapi.SR.get_type(vdisr),
                'vm_uuid': session.xenapi.VM.get_uuid(vdivm),
                'vm_name': session.xenapi.VM.get_name_label(vdivm),
                'vm_dev': session.xenapi.VBD.get_userdevice(vbd),
            }
            vdi_list.append(data)

    return vdi_list


if __name__ == '__main__':
    if len(sys.argv) < 3:
        script_name = sys.argv[0]
        usage = ('Usage: %s hostname username password')
        usage_ex = ('Ex.: %s 192.168.33.52 r0ot foobar')
        print(usage % script_name)
        print(usage_ex % script_name)
        sys.exit(1)

    host = sys.argv[1]
    username = sys.argv[2]
    password = sys.argv[3]

    try:
        session = XenAPI.Session('https://' + host)
        session.xenapi.login_with_password(username, password)
    except XenAPI.Failure as e:
        if e.details[0] == 'HOST_IS_SLAVE':
            session = XenAPI.Session('https://%s' % e.details[1])
            session.xenapi.login_with_password(username, password)
        else:
            raise SystemExit('XenAPI login Error : %s' % e.details[0])

    try:
        vms = get_all_vm(session)

        for vm in vms:
            if vm_filter(session, vm) is not None:
                vm_dict = session.xenapi.VM.get_record(vm)
                vmhostref = vm_dict['resident_on']

                if vmhostref == 'OpaqueRef:NULL':
                    resident_on = 'NULL'
                else:
                    resident_on = vmhostref = \
                        session.xenapi.host.get_name_label(vmhostref)

                print('%-15s: %s' % ('name_label', vm_dict['name_label']))
                print('%-15s: %s' % ('uuid', vm_dict['uuid']))
                # print('%-15s: %s' % ('vdbs', vm_dict['VBDs']))
                print('%-15s: %s' % ('power_state', vm_dict['power_state']))
                print('%-15s: %s' % ('resident_on', resident_on))

                for vbd in vm_dict['VBDs']:
                    for vdi in get_vdi_from_vbd(session, vbd):
                        for k in ('uuid', 'size', 'sr_name', 'sr_type'):
                            print('%-15s: %s' % ('disk_' + k, vdi[k]))

                print('\n')
    except Exception as e:
        raise SystemExit(e)
    finally:
        try:
            session.logut()
        except:
            pass
