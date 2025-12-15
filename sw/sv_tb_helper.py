def emit_ready_queue_worker_sv(num_chiplet, num_cluster, num_core):
    """
    Generate SystemVerilog tasks for ready queue workers.

    Args:
        num_chiplet (int): Number of chiplets.
        num_cluster (int): Number of clusters per chiplet.
        num_core (int): Number of cores per cluster.

    Returns:
        str: Generated SystemVerilog code for ready queue workers.
    """
    sv_code = []

    for chip in range(num_chiplet):
        for cluster in range(num_cluster):
            for core in range(num_core):
                task_name = f"chip{chip}_cluster{cluster}_core{core}_ready_queue_worker"
                sv_code.append(f"  task automatic {task_name}(input chip_id_t chip,\n"
                               f"                                         input int cluster,\n"
                               f"                                         input int core);\n"
                               f"    axi_pkg::resp_t                resp;\n"
                               f"    device_axi_lite_data_t         data;\n"
                               f"    device_axi_lite_addr_t         data_addr;\n"
                               f"    device_axi_lite_data_t         status;\n"
                               f"    device_axi_lite_addr_t         status_addr;\n"
                               f"    device_axi_lite_addr_t         done_addr;\n"
                               f"    bingo_hw_manager_done_info_full_t done_info;\n"
                               f"    device_axi_lite_data_t         done_payload;\n"
                               f"    int idx = core + cluster * NUM_CORES_PER_CLUSTER;\n"
                               f"    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;\n"                               
                               f"    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;\n"
                               f"    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;\n"
                               f"    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;\n"
                               f"    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;\n"
                               f"    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;\n"
                               f"\n"
                               f"    $display(\"%0t Chip{chip} READY[Core%0d,Cluster%0d] worker started, idx %0d\", $time, core, cluster, idx);\n"
                               f"    forever begin\n"
                               f"      fork \n"
                               f"      local_ready_drv_chip{chip}_cluster{cluster}_core{core}.send_ar(status_addr, '0);\n"
                               f"      local_ready_drv_chip{chip}_cluster{cluster}_core{core}.recv_r(status, resp);\n"
                               f"      join_none\n"
                               f"      repeat (5) @(posedge clk_i);\n"
                               f"      // Check the status\n"
                               f"      // If no task is ready, retry after some time\n"
                               f"      if (status[0]) begin\n"
                               f"        repeat (10) @(posedge clk_i);\n"
                               f"        continue;\n"
                               f"      end\n"
                               f"      // Here the core sees a task is ready\n"
                               f"      $display(\"%0t Chip{chip} READY[Core%0d,Cluster%0d] Reading Ready Queue...\", $time, core, cluster);\n"
                               f"      // Read the task id\n"
                               f"      fork\n"
                               f"      local_ready_drv_chip{chip}_cluster{cluster}_core{core}.send_ar(data_addr, '0);\n"
                               f"      local_ready_drv_chip{chip}_cluster{cluster}_core{core}.recv_r(data, resp);\n"
                               f"      join_none\n"
                               f"      repeat (5) @(posedge clk_i);\n"
                               f"      $display(\"%0t Chip{chip} READY[Core%0d,Cluster%0d] recvs task_id %0d\",\n"
                               f"              $time, core, cluster, data[TaskIdWidth-1:0]);\n"
                               f"      $display(\"%0t Chip{chip} READY[Core%0d,Cluster%0d] doing some work....\",\n"
                               f"              $time, core, cluster);                \n"
                               f"      repeat ($urandom_range(20, 50)) @(posedge clk_i);\n"
                               f"      $display(\"%0t Chip{chip} READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back\",\n"
                               f"              $time, core, cluster, data[TaskIdWidth-1:0]);\n"
                               f"      done_info.task_id     = data[TaskIdWidth-1:0];\n"
                               f"      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);\n"
                               f"      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);\n"
                               f"      done_info.reserved_bits = '0;\n"
                               f"      done_payload = device_axi_lite_data_t'(done_info);\n"
                               f"      fork\n"
                               f"           local_done_drv_chip{chip}.send_aw(done_addr, '0);\n"
                               f"           local_done_drv_chip{chip}.send_w(done_payload, {{DEV_DW/8{{1'b1}}}});\n"
                               f"      join\n"
                               f"      local_done_drv_chip{chip}.recv_b(resp);\n"
                               f"    end\n"
                               f"  endtask\n")
    return "\n".join(sv_code)

def emit_ready_queue_pollers_sv(num_chiplet, num_cluster, num_core):
    """
    Generate SystemVerilog code for initializing ready queue pollers.

    Args:
        num_chiplet (int): Number of chiplets.
        num_cluster (int): Number of clusters per chiplet.
        num_core (int): Number of cores per cluster.

    Returns:
        str: Generated SystemVerilog code for ready queue pollers.
    """
    sv_code = []

    sv_code.append("initial begin : ready_queue_pollers")
    sv_code.append("    wait (rst_ni);")
    sv_code.append("    repeat (5) @(posedge clk_i);")
    sv_code.append("    fork")

    for chip in range(num_chiplet):
        for cluster in range(num_cluster):
            for core in range(num_core):
                task_call = f"      chip{chip}_cluster{cluster}_core{core}_ready_queue_worker({chip}, {cluster}, {core});"
                sv_code.append(task_call)

    sv_code.append("    join_none")
    sv_code.append("  end")

    return "\n".join(sv_code)

if __name__ == "__main__":
    num_chiplet = 4
    num_cluster = 2
    num_core = 3
    sv_tasks = emit_ready_queue_worker_sv(num_chiplet, num_cluster, num_core)
    sv_pollers = emit_ready_queue_pollers_sv(num_chiplet, num_cluster, num_core)
    print(sv_tasks)
    print(sv_pollers)