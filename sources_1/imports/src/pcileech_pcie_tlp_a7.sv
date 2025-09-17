//
// PCILeech FPGA.
//
// PCIe controller module - TLP handling for Artix-7.
//
// (c) Ulf Frisk, 2018-2024
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_pcie_tlp_a7(
    input                   rst,
    input                   clk_pcie,
    input                   clk_sys,
    IfPCIeFifoTlp.mp_pcie   dfifo,
    
    // PCIe core receive/transmit data
    IfAXIS128.source        tlps_tx,
    IfAXIS128.sink_lite     tlps_rx,
    IfAXIS128.sink          tlps_static,
    IfShadow2Fifo.shadow    dshadow2fifo,
    input [15:0]            pcie_id,
    output                  led_signal
    );
    
    IfAXIS128 tlps_bar_rsp();
    IfAXIS128 tlps_cfg_rsp();
    
    // RXD - way to split up interface for multiplexing
    IfAXIS128 tlps_bar_rsp_to_pcie();
    IfAXIS128 tlps_to_tb();
    
    (* DONT_TOUCH = "yes", mark_debug = "true" *)
    reg BAR_data_requested = 0;
    wire BAR_dump;
    wire BAR_finished;
    wire max_hit;
    
    reg BAR_data_requested1 = 0;
    reg BAR_data_requested2 = 0;
    reg BAR_data_requested3 = 0;
    wire BAR_data_requested_span;
    
    assign BAR_data_requested_span = BAR_data_requested || BAR_data_requested1 || BAR_data_requested2 || BAR_data_requested3;
    
    always @ ( posedge clk_pcie ) begin
        BAR_data_requested1 <= BAR_data_requested;
        BAR_data_requested2 <= BAR_data_requested1;
        BAR_data_requested3 <= BAR_data_requested2;
    end
    
    wire FIFO_empty;
    
    reg BAR_dump_d;
    
    wire completion_filter;
    
    wire throttled;
    reg throttled_reg = 0;
    wire throttled_pulse;
    
    reg first_throttled = 0;
    reg ended = 0;
    wire ended_pulse;
    
    (* DONT_TOUCH = "yes", mark_debug = "true" *)
    wire send_FFs;
    
    assign send_FFs = ( throttled_pulse && ~first_throttled ) || ( ended_pulse && first_throttled );
    
    assign ended_pulse = ~led_signal && ended;
    
    assign throttled = led_signal && ~tlps_tx.tready;
    
    always @ ( posedge clk_pcie ) begin
        throttled_reg <= throttled;
    end
    
    assign throttled_pulse = throttled && ~throttled_reg; 
    wire [127:0] dummy_tlp_tdata = { 128'b11111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111 };
    
    assign tlps_bar_rsp_to_pcie.tdata       = (BAR_data_requested_span) ? 128'd0 : tlps_bar_rsp.tdata;       // normal to span
    assign tlps_bar_rsp_to_pcie.tkeepdw     = (BAR_data_requested_span) ? 4'd0   : tlps_bar_rsp.tkeepdw;
    assign tlps_bar_rsp_to_pcie.tvalid      = (BAR_data_requested_span) ? 1'b0   : tlps_bar_rsp.tvalid;
    assign tlps_bar_rsp_to_pcie.tlast       = (BAR_data_requested_span) ? 1'b0   : tlps_bar_rsp.tlast;
    assign tlps_bar_rsp_to_pcie.tuser       = (BAR_data_requested_span) ? 9'd0   : tlps_bar_rsp.tuser;
    assign tlps_bar_rsp_to_pcie.has_data    = (BAR_data_requested_span) ? 1'b0   : tlps_bar_rsp.has_data;
        
    assign tlps_bar_rsp.tready              = (BAR_data_requested_span) ? 1'b1   : tlps_bar_rsp_to_pcie.tready; // not in lite IF
    
    
    assign tlps_to_tb.tdata       = (send_FFs) ? dummy_tlp_tdata : (BAR_data_requested_span) ? tlps_bar_rsp.tdata       : tlps_filtered.tdata ;
    assign tlps_to_tb.tkeepdw     = (send_FFs) ? 4'b1111         : (BAR_data_requested_span) ? tlps_bar_rsp.tkeepdw     : tlps_filtered.tkeepdw ;
    assign tlps_to_tb.tvalid      = (send_FFs) ? 1'b1            : (BAR_data_requested_span) ? tlps_bar_rsp.tvalid      : tlps_filtered.tvalid ;
    assign tlps_to_tb.tlast       = (send_FFs) ? 1'b1            : (BAR_data_requested_span) ? tlps_bar_rsp.tlast       : tlps_filtered.tlast ;
    assign tlps_to_tb.tuser       = (send_FFs) ? 9'b000000001    : (BAR_data_requested_span) ? tlps_bar_rsp.tuser       : tlps_filtered.tuser ;
//    assign tlps_to_tb.has_data    = (BAR_data_requested) ? tlps_bar_rsp.has_data    : tlps_filtered ;   // not in lite IF

    always @ ( posedge clk_pcie ) begin
        if ( rst || ~led_signal ) begin
            first_throttled <= 1'b0;
        end
        else if ( throttled_pulse ) begin
            first_throttled <= 1'b1;
        end
    end
    
    always @ ( posedge clk_pcie ) begin
        if ( rst ) begin
            ended <= 1'b0;
        end
        else begin
            ended <= led_signal;
        end
    end

    always @ ( posedge clk_pcie ) begin
        BAR_dump_d <= BAR_dump;
    end

    always @ ( posedge clk_pcie ) begin
        if ( rst || ( BAR_finished && FIFO_empty ) ) 
            BAR_data_requested <= 0;
        else if ( BAR_dump && ~BAR_dump_d )
            BAR_data_requested <= 1;
    end    
        
    // ------------------------------------------------------------------------
    // Convert received TLPs from PCIe core and transmit onwards:
    // ------------------------------------------------------------------------
    IfAXIS128 tlps_filtered();
    
    pcileech_tlps128_bar_controller i_pcileech_tlps128_bar_controller(
        .rst            ( rst                           ),
        .clk            ( clk_pcie                      ),
        .bar_en         ( dshadow2fifo.bar_en           ),
        .pcie_id        ( pcie_id                       ),
        .tlps_in        ( tlps_rx                       ),
        .tlps_out       ( tlps_bar_rsp.source           ),
        .BAR_requested  ( BAR_data_requested            ),
        .BAR_finished   ( BAR_finished                  )
    );
    
    pcileech_tlps128_cfgspace_shadow i_pcileech_tlps128_cfgspace_shadow(
        .rst            ( rst                           ),
        .clk_pcie       ( clk_pcie                      ),
        .clk_sys        ( clk_sys                       ),
        .tlps_in        ( tlps_rx                       ),
        .pcie_id        ( pcie_id                       ),
        .dshadow2fifo   ( dshadow2fifo                  ),
        .tlps_cfg_rsp   ( tlps_cfg_rsp.source           )
    );
    
    pcileech_tlps128_filter i_pcileech_tlps128_filter(
        .rst            ( rst                           ),
        .clk_pcie       ( clk_pcie                      ),
        .alltlp_filter  ( dshadow2fifo.alltlp_filter    ),
        .cfgtlp_filter  ( dshadow2fifo.cfgtlp_filter    ),
        .tlps_in        ( tlps_rx                       ),
        .tlps_out       ( tlps_filtered.source_lite     ), 
        .led_signal     ( led_signal || ended           ),
        .completion_filter ( completion_filter          )
    );
    
    pcileech_tlps128_dst_fifo i_pcileech_tlps128_dst_fifo(
        .rst            ( rst                           ),
        .clk_pcie       ( clk_pcie                      ),
        .clk_sys        ( clk_sys                       ),
        .tlps_in        ( tlps_to_tb.sink_lite          ), //tlps_filtered.sink_lite       ),
        .dfifo          ( dfifo                         ),
        .FIFO_empty     ( FIFO_empty                    )
    );
    
    // ------------------------------------------------------------------------
    // TX data received from FIFO
    // ------------------------------------------------------------------------
    IfAXIS128 tlps_rx_fifo();
    
    pcileech_tlps128_src_fifo i_pcileech_tlps128_src_fifo(
        .rst            ( rst                           ),
        .clk_pcie       ( clk_pcie                      ),
        .clk_sys        ( clk_sys                       ),
        .dfifo_tx_data  ( dfifo.tx_data                 ),
        .dfifo_tx_last  ( dfifo.tx_last                 ),
        .dfifo_tx_valid ( dfifo.tx_valid                ),
        .tlps_out       ( tlps_rx_fifo.source           ),
        .BAR_dump       ( BAR_dump                      )
    );
    
    pcileech_tlps128_sink_mux1 i_pcileech_tlps128_sink_mux1(
        .rst            ( rst                           ),
        .clk_pcie       ( clk_pcie                      ),
        .pcie_id        ( pcie_id                       ),
        .tlps_out       ( tlps_tx                       ),
        .tlps_in1       ( tlps_cfg_rsp.sink             ),
        .tlps_in2       ( tlps_bar_rsp_to_pcie.sink     ),//tlps_bar_rsp.sink             ),
        .tlps_in3       ( tlps_rx_fifo.sink             ),
        .tlps_in4       ( tlps_static                   ),
        .led_signal     ( led_signal                    ),
        .completion_filter ( completion_filter          )
    );
    

endmodule



// ------------------------------------------------------------------------
// TLP-AXI-STREAM destination:
// Forward the data to output device (FT601, etc.). 
// ------------------------------------------------------------------------
module pcileech_tlps128_dst_fifo(
    input                   rst,
    input                   clk_pcie,
    input                   clk_sys,
    IfAXIS128.sink_lite     tlps_in,
    IfPCIeFifoTlp.mp_pcie   dfifo,
    output                  FIFO_empty
);
    
    (* DONT_TOUCH = "yes", mark_debug = "true" *)
    wire         tvalid;
    wire [127:0] tdata;
    
    (* DONT_TOUCH = "yes", mark_debug = "true" *)
    wire [3:0]   tkeepdw;
    wire         tlast;
    wire         first;
    
//    wire         FIFO_empty;
       
    fifo_134_134_clk2 i_fifo_134_134_clk2 (
        .rst        ( rst               ),
        .wr_clk     ( clk_pcie          ),
        .rd_clk     ( clk_sys           ),
        .din        ( { tlps_in.tuser[0], tlps_in.tlast, tlps_in.tkeepdw, tlps_in.tdata } ),
        .wr_en      ( tlps_in.tvalid    ),
        .rd_en      ( dfifo.rx_rd_en    ),
        .dout       ( { first, tlast, tkeepdw, tdata } ),
        .full       (                   ),
        .empty      ( FIFO_empty                  ),
        .valid      ( tvalid            )
    );

    assign dfifo.rx_data[0]  = tdata[31:0];
    assign dfifo.rx_data[1]  = tdata[63:32];
    assign dfifo.rx_data[2]  = tdata[95:64];
    assign dfifo.rx_data[3]  = tdata[127:96];
    assign dfifo.rx_first[0] = first;
    assign dfifo.rx_first[1] = 0;
    assign dfifo.rx_first[2] = 0;
    assign dfifo.rx_first[3] = 0;
    assign dfifo.rx_last[0]  = tlast && (tkeepdw == 4'b0001);
    assign dfifo.rx_last[1]  = tlast && (tkeepdw == 4'b0011);
    assign dfifo.rx_last[2]  = tlast && (tkeepdw == 4'b0111);
    assign dfifo.rx_last[3]  = tlast && (tkeepdw == 4'b1111);
    assign dfifo.rx_valid[0] = tvalid && tkeepdw[0];
    assign dfifo.rx_valid[1] = tvalid && tkeepdw[1];
    assign dfifo.rx_valid[2] = tvalid && tkeepdw[2];
    assign dfifo.rx_valid[3] = tvalid && tkeepdw[3];

endmodule



// ------------------------------------------------------------------------
// TLP-AXI-STREAM FILTER:
// Filter away certain packet types such as CfgRd/CfgWr or non-Cpl/CplD
// ------------------------------------------------------------------------
module pcileech_tlps128_filter(
    input                   rst,
    input                   clk_pcie,
    input                   alltlp_filter,
    input                   cfgtlp_filter,
    IfAXIS128.sink_lite     tlps_in,
    IfAXIS128.source_lite   tlps_out, 
    input                   led_signal,
    input                   completion_filter
);

    bit [127:0]     tdata;
    bit [3:0]       tkeepdw;
    bit             tvalid  = 0;
    bit [8:0]       tuser;
    bit             tlast;
    
    (* DONT_TOUCH = "yes", mark_debug = "true" *)
    reg [35:0]      completions_rcvd = 0;
    
    (* DONT_TOUCH = "yes", mark_debug = "true" *)
    reg [35:0]      succ_completions_rcvd = 0;
    
    assign tlps_out.tdata   = tdata;
    assign tlps_out.tkeepdw = tkeepdw;
    assign tlps_out.tvalid  = tvalid;
    assign tlps_out.tuser   = tuser;
    assign tlps_out.tlast   = tlast;
    
    bit  filter = 0;
    wire first = tlps_in.tuser[0];
    
    (* DONT_TOUCH = "yes", mark_debug = "true" *)
    wire all_tlp_filter_debug = alltlp_filter;
    
    (* DONT_TOUCH = "yes", mark_debug = "true" *)
    wire cfg_tlp_filter_debug = cfgtlp_filter;
    
    
    (* DONT_TOUCH = "yes", mark_debug = "true" *)
    wire is_tlphdr_cpl = first && (
                        (tlps_in.tdata[31:25] == 7'b0000101) ||      // Cpl:  Fmt[2:0]=000b (3 DW header, no data), Cpl=0101xb
                        (tlps_in.tdata[31:25] == 7'b0100101)         // CplD: Fmt[2:0]=010b (3 DW header, data),    CplD=0101xb
                      );
                      
    wire successful = is_tlphdr_cpl && (tlps_in.tdata[47:45] == 3'b000);
                      
    (* DONT_TOUCH = "yes", mark_debug = "true" *)
    wire is_tlphdr_cfg = first && (
                        (tlps_in.tdata[31:25] == 7'b0000010) ||      // CfgRd: Fmt[2:0]=000b (3 DW header, no data), CfgRd0/CfgRd1=0010xb
                        (tlps_in.tdata[31:25] == 7'b0100010)         // CfgWr: Fmt[2:0]=010b (3 DW header, data),    CfgWr0/CfgWr1=0010xb
                      );
    
    (* DONT_TOUCH = "yes", mark_debug = "true" *)                  
    wire filter_next = (filter && !first) || (cfgtlp_filter && first && is_tlphdr_cfg) || ((alltlp_filter) && first && !is_tlphdr_cpl && !is_tlphdr_cfg) || ( first && ( led_signal && completion_filter ) && is_tlphdr_cpl ) ;
    
    always @ ( posedge clk_pcie ) begin
        if ( rst || ~led_signal ) begin
            completions_rcvd = 8'h00000000;
            succ_completions_rcvd = 8'h00000000;
        end
        else if ( first && led_signal && is_tlphdr_cpl ) begin
            completions_rcvd = completions_rcvd + 1'b1;
            if ( successful )
                succ_completions_rcvd = succ_completions_rcvd + 1'b1;
        end
    end
                      
    always @ ( posedge clk_pcie ) begin
        tdata   <= tlps_in.tdata;
        tkeepdw <= tlps_in.tkeepdw;
        tvalid  <= tlps_in.tvalid && !filter_next && !rst;
        tuser   <= tlps_in.tuser;
        tlast   <= tlps_in.tlast;
        filter  <= filter_next && !rst;
    end
    
endmodule



// ------------------------------------------------------------------------
// RX FROM FIFO - TLP-AXI-STREAM:
// Convert 32-bit incoming data to 128-bit TLP-AXI-STREAM to be sent onwards to mux/pcie core. 
// ------------------------------------------------------------------------
module pcileech_tlps128_src_fifo (
    input                   rst,
    input                   clk_pcie,
    input                   clk_sys,
    input [31:0]            dfifo_tx_data,
    input                   dfifo_tx_last,
    input                   dfifo_tx_valid,
    IfAXIS128.source        tlps_out,
    output                  BAR_dump
);

    // 1: 32-bit -> 128-bit state machine:
    bit [127:0] tdata;
    bit [3:0]   tkeepdw = 0;
    bit         tlast;
    bit         first   = 1;
    wire        tvalid  = tlast || tkeepdw[3];
    
//    (* DONT_TOUCH = "yes", mark_debug = "true" *) 
    wire        outvalid;
    reg         BAR_dump_reg = 0;
    reg         BAR_dump_reg1 = 0;
    reg         BAR_dump_reg2 = 0;
    reg         BAR_dump_reg3 = 0;
    reg         BAR_dump_reg4 = 0;
    
    wire        BAR_dump_pulse;
    
    assign      BAR_dump_pulse = BAR_dump && BAR_dump_reg && ~BAR_dump_reg4;
    
    always @ ( posedge clk_pcie ) begin
        BAR_dump_reg <= BAR_dump;
        BAR_dump_reg1 <= BAR_dump_reg;
        BAR_dump_reg2 <= BAR_dump_reg1;
        BAR_dump_reg3 <= BAR_dump_reg2;
        BAR_dump_reg4 <= BAR_dump_reg3;
    end
    
    always @ ( posedge clk_sys )
        if ( rst ) begin
            tkeepdw <= 0;
            tlast   <= 0;
            first   <= 1;
//            BAR_dump<= 0;
        end
        else begin
            tlast   <= dfifo_tx_valid && dfifo_tx_last;
            tkeepdw <= tvalid ? (dfifo_tx_valid ? 4'b0001 : 4'b0000) : (dfifo_tx_valid ? ((tkeepdw << 1) | 1'b1) : tkeepdw);
            first   <= tvalid ? tlast : first;
            if ( dfifo_tx_valid ) begin
                if ( tvalid || !tkeepdw[0] )
                    tdata[31:0]   <= dfifo_tx_data;
                if ( !tkeepdw[1] )
                    tdata[63:32]  <= dfifo_tx_data;
                if ( !tkeepdw[2] )
                    tdata[95:64]  <= dfifo_tx_data;
                if ( !tkeepdw[3] )
                    tdata[127:96] <= dfifo_tx_data;   
            end
        end
		
    // 2.1 - packet count (w/ safe fifo clock-crossing).
    bit [10:0]  pkt_count       = 0;
    wire        pkt_count_dec   = outvalid && tlps_out.tlast; //tlps_out.tvalid && tlps_out.tlast;
    wire        pkt_count_inc;
    wire [10:0] pkt_count_next  = pkt_count + pkt_count_inc - pkt_count_dec;
    assign tlps_out.has_data    = (pkt_count_next > 0) && ~BAR_dump;
    
    fifo_1_1_clk2 i_fifo_1_1_clk2(
        .rst            ( rst                       ),
        .wr_clk         ( clk_sys                   ),
        .rd_clk         ( clk_pcie                  ),
        .din            ( 1'b1                      ),
        .wr_en          ( tvalid && tlast           ),
        .rd_en          ( 1'b1                      ),
        .dout           (                           ),
        .full           (                           ),
        .empty          (                           ),
        .valid          ( pkt_count_inc             )
    );
	
    always @ ( posedge clk_pcie ) begin
        pkt_count <= rst ? 0 : pkt_count_next;
    end
        
    assign BAR_dump = ( tlps_out.tuser[0] && (tlps_out.tdata[28:24] == 5'b11111) );
        
    // 2.2 - submit to output fifo - will feed into mux/pcie core.
    //       together with 2.1 this will form a low-latency "packet fifo".
    fifo_134_134_clk2_rxfifo i_fifo_134_134_clk2_rxfifo(
        .rst            ( rst || BAR_dump_pulse                       ),
        .wr_clk         ( clk_sys                   ),
        .rd_clk         ( clk_pcie                  ),
        .din            ( { first, tlast, tkeepdw, tdata } ),
        .wr_en          ( tvalid                    ),
        .rd_en          ( tlps_out.tready && (pkt_count_next > 0) ),
        .dout           ( { tlps_out.tuser[0], tlps_out.tlast, tlps_out.tkeepdw, tlps_out.tdata } ),
        .full           (                           ),
        .empty          (                           ),
        .valid          ( outvalid                  )//tlps_out.tvalid           )
    );
    
    assign tlps_out.tvalid = outvalid && ~BAR_dump;

endmodule



// ------------------------------------------------------------------------
// RX MUX - TLP-AXI-STREAM:
// Select the TLP-AXI-STREAM with the highest priority (lowest number) and
// let it transmit its full packet.
// Each incoming stream must have latency of 1CLK. 
// ------------------------------------------------------------------------
module pcileech_tlps128_sink_mux1 (
    input                       clk_pcie,
    input                       rst,
    input [15:0]                pcie_id,
    IfAXIS128.source            tlps_out,
    IfAXIS128.sink              tlps_in1,
    IfAXIS128.sink              tlps_in2,
    IfAXIS128.sink              tlps_in3,
    IfAXIS128.sink              tlps_in4,
    output                      led_signal,
    output                      completion_filter
);


//    IfAXIS128.source    tlps_out7;
//    IfAXIS128.sink      tlps_in7;
    
    wire [127:0]        tlps_out7_tdata;
    wire [3:0]          tlps_out7_tkeepdw;
    wire                tlps_out7_tvalid;
    wire                tlps_out7_tlast;
    wire [8:0]          tlps_out7_tuser;
    wire                tlps_out7_tready;
    wire                tlps_out7_has_data;
    
    wire [127:0]        tlps_in7_tdata;
    wire [3:0]          tlps_in7_tkeepdw;
    wire                tlps_in7_tvalid;
    wire                tlps_in7_tlast;
    wire [8:0]          tlps_in7_tuser;
    wire                tlps_in7_tready;    
    wire                tlps_in7_has_data;
    
    bit [141:0]         tlps_out7_concat;
    bit [141:0]         tlps_in7_concat;
    
    bit                 tlps7_wr_en;
    bit                 tlps7_rd_en;
    
    bit                 first;
    bit [7:0]           bus_num;
    bit [4:0]           device_num;
    bit [2:0]           function_num;
    
    assign bus_num              = pcie_id [7:0];
    assign device_num           = pcie_id [12:8];
    assign function_num         = pcie_id [15:13];
    
    bit                 empty;
    bit                 rep_fifo_valid;
    
    reg                 started = 0;
    reg                 finished = 0;
    reg                 end_pkt = 0;
    
    reg [39:0]          rep_counter = 0;    // RXD
    reg [35:0]          reps_requested = 0;
    
    (* DONT_TOUCH = "yes", mark_debug = "true" *)
    reg [7:0]           tag_offset = 0;
    (* DONT_TOUCH = "yes", mark_debug = "true" *)
    bit [7:0]           tag_sum;
    
    (* DONT_TOUCH = "yes", mark_debug = "true" *)    
    wire                bpause;
    reg                 bpause_reg = 0;
    
    reg                 batch_pause = 0;
    reg [19:0]          batch_reps_requested = 0;
    
    reg [19:0]          delay_counter = 0;
    reg [19:0]          delay_requested = 0;

    reg                 paused = 0;
//    bit                 last_paused;
    reg                 last_paused = 0;
    
    bit                 ready_again;
    reg                 ready_d = 0;
    
    reg [19:0]          not_ready_ctr = 0;
    reg [19:0]          not_ready_limit = 0;
    
    reg                 compl_filter = 1;
    reg                 compl_filter_d = 1;
    
    reg                 stop_on_throttling = 0;

    rep_fifo_generator_0 repeat_fifo (
        .srst           ( rst                   ),
        .clk            ( clk_pcie              ),
        .din            ( tlps_out7_concat      ),     // RXD: need to concat entire interface
        .wr_en          ( tlps7_wr_en           ),
        .rd_en          ( tlps7_rd_en           ),
        .dout           ( tlps_in7_concat       ),
        //.almost_full    (                   ),
        .full           (            ),
        .empty          ( empty                 ),
        .valid          ( rep_fifo_valid        )
    );

    bit [2:0] id = 0;
    
    reg                 id_returned = 0;
    reg                 one_more = 0;
    
    assign tlps_out7_concat     = { tlps_out7_tdata, tlps_out.tkeepdw, tlps_out.tlast, tlps_out.tuser }; // tlps_out7_tkeepdw, tlps_out7_tlast, tlps_out7_tuser };
    
//    assign tlps_in7_tdata       = tlps_in7_concat [141:14];
    assign tlps_in7_tdata       = (first) ? { tlps_in7_concat[141:78], bus_num, device_num, function_num, tag_sum, tlps_in7_concat[53:14]} :
                                  tlps_in7_concat [141:14];
    assign tlps_in7_tkeepdw     = tlps_in7_concat [13:10];
    assign tlps_in7_tvalid      = ( ~paused ) && ( ( rep_fifo_valid ) || ( ( last_paused || id_returned ) && first ) ) ;        
    assign tlps_in7_tlast       = tlps_in7_concat [9];
    assign tlps_in7_tuser       = tlps_in7_concat [8:0];
    assign tlps_in7_has_data    = finished && ~empty;       // tlps_in7_concat [0];
    
    
    assign tlps_out.has_data    = tlps_in7_has_data || tlps_in1.has_data || tlps_in2.has_data || tlps_in3.has_data || tlps_in4.has_data;
    
    assign tlps_out.tdata       = (id==7) ? tlps_in7_tdata :
                                  (id==1) ? tlps_in1.tdata :
                                  (id==2) ? tlps_in2.tdata :
                                  //(id==3) ? tlps_in3.tdata :
                                  (id==3) ? (first) ? { tlps_in3.tdata[127:64],  bus_num, device_num, function_num, tlps_in3.tdata[47:0]}: tlps_in3.tdata :
                                  (id==4) ? tlps_in4.tdata : 0;
    
//    assign tlps_out7_tdata      = (finished) ? tlps_in7_tdata :
//                                  (first) ? {tlps_in3.tdata[127:64], bus_num, device_num, function_num, tlps_in3.tdata[47:0]} 
//                                  : tlps_in3.tdata;
    assign tlps_out7_tdata      = (finished) ? tlps_in7_concat [141:14] :
                                  tlps_in3.tdata;
    
    assign tlps_out.tkeepdw     = (id==7) ? tlps_in7_tkeepdw :
                                  (id==1) ? tlps_in1.tkeepdw :
                                  (id==2) ? tlps_in2.tkeepdw :
                                  (id==3) ? tlps_in3.tkeepdw :
                                  (id==4) ? tlps_in4.tkeepdw : 0;
    
    assign tlps_out.tlast       = (id==7) ? tlps_in7_tlast :
                                  (id==1) ? tlps_in1.tlast :
                                  (id==2) ? tlps_in2.tlast :
                                  (id==3) ? tlps_in3.tlast :
                                  (id==4) ? tlps_in4.tlast : 0;
    
    assign tlps_out.tuser       = (id==7) ? tlps_in7_tuser :
                                  (id==1) ? tlps_in1.tuser :
                                  (id==2) ? tlps_in2.tuser :
                                  (id==3) ? tlps_in3.tuser :
                                  (id==4) ? tlps_in4.tuser : 0;
                                  
    assign first                = tlps_out.tuser[0];                               
    
    assign tlps_out.tvalid      = (id==7) ? tlps_in7_tvalid :
                                  (id==1) ? tlps_in1.tvalid :
                                  (id==2) ? tlps_in2.tvalid :
                                  (id==3) ? tlps_in3.tvalid :
                                  (id==4) ? tlps_in4.tvalid : 0;
    
    wire [2:0] id_next_newsel   = tlps_in7_has_data ? 7 :
                                  tlps_in1.has_data ? 1 :       // RXD: has data will probably be finished && ~empty
                                  tlps_in2.has_data ? 2 :
                                  tlps_in3.has_data ? 3 :
                                  tlps_in4.has_data ? 4 : 0;
    
    wire [2:0] id_next          = ((id==0) || (tlps_out.tvalid && tlps_out.tlast)) ? id_next_newsel : id;
    
    assign tlps_in7_tready      = tlps_out.tready && (id_next==7);
    assign tlps_in1.tready      = tlps_out.tready && (id_next==1);
    assign tlps_in2.tready      = tlps_out.tready && (id_next==2);
    assign tlps_in3.tready      = tlps_out.tready && (id_next==3);
    assign tlps_in4.tready      = tlps_out.tready && (id_next==4);
    
    assign tlps7_wr_en = ( ( (id==3) && tlps_in3.tvalid && ( started || ( first && tlps_in3.tdata[63] ) ) ) || ( finished && (id==7) && (tlps_in7_tvalid || ( ~paused && ready_again)) && tlps_in7_tready ) ) && (( rep_counter <= reps_requested ) || one_more);
    assign tlps7_rd_en = tlps_in7_has_data && tlps_in7_tready && ~paused;
     
    assign led_signal = started || finished; // || (id==7) ; 
    
    assign tag_sum = tag_offset; // + tlps_in7_concat[61:54];
    
    assign ready_again = tlps_in7_tready && ~ready_d;   // RXD: rising edge of ready
    
//    assign last_paused = ( delay_counter >= delay_requested ) ? paused : 0 ;

    assign bpause = first && finished && tlps_out7_tdata[63] && ~last_paused;
    
    assign completion_filter = compl_filter || compl_filter_d;
    
    always @ ( posedge clk_pcie ) begin
        compl_filter_d <= compl_filter;
    end
    
    always @ ( posedge clk_pcie ) begin
        id <= rst ? 0 : id_next;
    end
    
    always @ ( posedge clk_pcie ) begin
        if ( rst ) begin
            started <= 1'b0;
            finished <= 1'b0;
            end_pkt <= 1'b0;
            compl_filter <= 1'b1;
        end
        else begin
            if ( ((rep_counter > reps_requested) && empty)) // || ( not_ready_ctr == not_ready_limit) )
                begin
                    finished <= 1'b0;
                    started <= 1'b0;
                    end_pkt <= 1'b0;
                    compl_filter <= 1'b1;
                    stop_on_throttling <= 1'b0;
                end
            if ( id==3 ) begin
                if ( ~started && first && tlps_in3.tdata[63] ) begin
                    started <= 1'b1;
                    if ( tlps_in3.tdata[60] ) begin
                        compl_filter <= 1'b0;
                        reps_requested[19:0] <= tlps_in3.tdata[59:40];
                        reps_requested[35:20] <= 16'h0000;
                    end
                    else begin
                        reps_requested[34:15] <= tlps_in3.tdata[59:40];     // RXD: changed from 34:13 and 61:40
                        reps_requested[14:0] <= 15'b000000000000000;
                    end
                    
                    if ( tlps_in3.tdata[61] ) begin
                        stop_on_throttling <= 1'b1;
                    end
                end              
                else if ( started && ( tlps_in3.tlast && ( end_pkt || ( first && tlps_in3.tdata[62] ) ) ) ) begin
                    finished <= 1'b1;
                    started <= 1'b0;
                    end_pkt <= 1'b0;
                end
                else if ( started && first && tlps_in3.tdata[62] ) 
                    end_pkt <= 1'b1;
                else if ( started && first && tlps_in3.tdata[61] )
                    batch_reps_requested <= tlps_in3.tdata[59:40];
                if ( started && first && tlps_in3.tdata[62] )
                    delay_requested <= tlps_in3.tdata[59:40];
            end
        end
    end
    
    // RXD: process to count up how many repeat sends are needed
    always @ ( posedge clk_pcie )
        if ( rst || ( !finished ) )
            rep_counter <= 40'h0000000000;  
        else if ( !tlps_out.tready && (id_next==7) && stop_on_throttling )
            rep_counter <= reps_requested + 40'b1; 
        else if ( tlps7_rd_en )      // counter/tester signal
            rep_counter <= rep_counter + 40'b1;  
    
            
    always @ ( posedge clk_pcie )
        if ( rst || ( ~bpause && ~batch_pause && ( delay_counter >= delay_requested ) ) || ( ( bpause || batch_pause ) && ( delay_counter >= batch_reps_requested ) ) ) // RXD removed last term - can't remember why it might be needed || ( !tlps_in7_has_data ) )
        //if ( rst || ( ~batch_pause && ( delay_counter >= delay_requested ) ) || ( batch_pause && ( delay_counter >= batch_reps_requested ) ) )
            begin
                paused <= 0;
                delay_counter <= 20'h00000; 
            end
        else if ( (id==7) && (id_next==7) && tlps_in7_tlast )//&& tlps7_rd_en ) // last term to stop paused starting again while PCIe core isn't ready
            begin
                paused <= 1;
                delay_counter <= delay_counter + 20'b1;
            end
        else if ( paused )
            delay_counter <= delay_counter + 20'b1;

    always @ ( posedge clk_pcie )
        if ( rst )
            last_paused <= 0;
//        else if ( paused && ( ( ~batch_pause && ( delay_counter >= delay_requested ) ) || ( batch_pause && ( delay_counter >= batch_reps_requested ) ) ) )
        else if ( paused && ( ( ~bpause && ~batch_pause && ( delay_counter >= delay_requested ) ) || ( ( bpause || batch_pause ) && ( delay_counter >= batch_reps_requested ) ) ) )
            last_paused <= 1;
        else 
            last_paused <= 0;

    // RXD: delayed 'ready' for rising edge detection
    always @ ( posedge clk_pcie )
        if ( rst )
            ready_d <= 0;
        else
            ready_d <= tlps_in7_tready;

    // RXD: delayed 'ready' for rising edge detection
    always @ ( posedge clk_pcie )
        if ( rst )
            id_returned <= 0;
        else if ( (id!=7) && (id_next==7) )
            id_returned <= 1;
        else
            id_returned <= 0;

    // RXD: case where we reach max reps midway thru multi cycle TLP
    always @ ( posedge clk_pcie )
        if ( rst )
            one_more <= 0;
        else if ( (( rep_counter == reps_requested ) || (( rep_counter == (reps_requested + 1)) && (!tlps_in7_tready)) || one_more) && ( ~tlps_in7_tlast ) )
            one_more <= 1;
        else 
            one_more <= 0;


    always @ ( posedge clk_pcie )
        if ( rst || ~finished || last_paused || ( first && ~tlps_out7_tdata[63] ) || ( ( bpause || batch_pause ) && ( delay_counter >= batch_reps_requested ) ) ) 
            batch_pause <= 0;
        else if ( first && finished && tlps_out7_tdata[63] )
            batch_pause <= 1;
    // RXD: concern, bpause stays high one extra cycle when rd/wr_en go high, shouldn't be a problem since its always &&ed with delay_count condition which resets paused


    always @ ( posedge clk_pcie ) begin
        bpause_reg <= bpause;
    end
    
    always @ ( posedge clk_pcie ) begin
        if ( rst || started ) begin
            tag_offset <= 0;
        end
        else if ( finished && tlps_out.tlast && tlps7_rd_en ) begin //( ~bpause && bpause_reg ) begin
            tag_offset <= tag_offset + 1'b1;
        end
    end    


    always @ ( posedge clk_pcie )
        if ( rst || tlps_in7_tready )
            not_ready_ctr <= 0;
        else if ( (id==7) && ~tlps_in7_tready )
            not_ready_ctr <= not_ready_ctr + 20'b1;


endmodule


