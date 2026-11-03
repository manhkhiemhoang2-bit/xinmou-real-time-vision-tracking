// M7 only: 8x8 contour occupancy + exact four-neighbour exterior flood fill.
// Captured edge and completed exterior maps are double buffered. No shared
// video timing changes: output controls and memory data both take one clock.
// Display includes contours and enclosed interiors; open exterior stays black.
module alg_region_fill_96 #(
 parameter IMG_WIDTH=1280, IMG_HEIGHT=720, MORPH_FILL=1'b1
)(
 input wire I_clk,I_rst_n,
 input wire [95:0] I_tdata,
 input wire I_tvalid,I_tlast,I_tuser,I_tready,
 output wire [95:0] O_tdata,
 output reg O_tvalid,O_tlast,O_tuser,
 output wire O_tready
);
 localparam COLS=IMG_WIDTH/8, ROWS=IMG_HEIGHT/8, N=COLS*ROWS;
 localparam CW=$clog2(COLS), RW=$clog2(ROWS), AW=$clog2(N);
 localparam XW=$clog2(IMG_WIDTH/4);
 reg [XW-1:0] x;
 reg [10:0] y;
 wire [XW-1:0] xx=I_tuser ? 0:x;
 wire [10:0] yy=I_tuser ? 0:y;
 wire [CW-1:0] bx=xx>>1;
 wire [RW-1:0] by=yy>>3;
 wire [AW-1:0] video_addr=by*COLS+bx;
 wire edge_hit=I_tdata[95]|I_tdata[71]|I_tdata[47]|I_tdata[23];
 reg [COLS-1:0] row_acc;
 reg cap_bank,display_bank,result_valid,cap_complete;
 reg busy,ready,ready_bank,proc_edge_bank,proc_vis_bank;
 wire sof=I_tvalid && I_tuser;
 wire start_job=sof && cap_complete && !busy;
 wire next_display=ready ? ready_bank:display_bank;
 wire cap_write=I_tvalid && yy[2:0]==7 && xx[0];
 wire cap_value=row_acc[bx]|edge_hit;
 reg edge0[0:N-1]; //synthesis ram_style = bram
 reg edge1[0:N-1]; //synthesis ram_style = bram
 reg vis0[0:N-1];  //synthesis ram_style = bram
 reg vis1[0:N-1];  //synthesis ram_style = bram
 reg [CW+RW-1:0] queue[0:N-1]; //synthesis ram_style = bram
 reg [AW:0] head,tail;
 reg [CW+RW-1:0] q_head;
 reg [AW-1:0] proc_addr,init_addr;
 reg [CW-1:0] init_x,cur_x;
 reg [RW-1:0] init_y,cur_y;
 reg q_edge0,q_edge1,q_vis0,q_vis1;
 wire [AW-1:0] addr0=display_bank==0 ? video_addr:proc_addr;
 wire [AW-1:0] addr1=display_bank==1 ? video_addr:proc_addr;
 localparam IDLE=0,INIT=1,POP=2,POP_GET=3,REQ=4,WAIT_RAM=5,TEST=6;
 reg [2:0] state;
 reg [1:0] dir;
 reg [CW-1:0] nx;
 reg [RW-1:0] ny;
 reg neighbor_valid;
 always @* begin
  nx=cur_x;ny=cur_y;neighbor_valid=1;
  case(dir)
   0: begin nx=cur_x-1'b1;neighbor_valid=cur_x!=0;end
   1: begin nx=cur_x+1'b1;neighbor_valid=cur_x<COLS-1;end
   2: begin ny=cur_y-1'b1;neighbor_valid=cur_y!=0;end
   3: begin ny=cur_y+1'b1;neighbor_valid=cur_y<ROWS-1;end
  endcase
 end
 wire init_border=init_x==0||init_x==COLS-1||init_y==0||init_y==ROWS-1;
 wire visited=proc_vis_bank ? q_vis1:q_vis0;
 wire blocked=proc_edge_bank ? q_edge1:q_edge0;
 wire enqueue=(state==TEST)&&!visited&&!blocked;
 wire vis_write=(state==INIT)||enqueue;
 wire [AW-1:0] vis_write_addr=state==INIT ? init_addr:proc_addr;
 wire vis_write_value=state==INIT ? init_border:1'b1;
 // No memory reset: INIT clears the entire processing map before it is read.
 always @(posedge I_clk) begin
  if(cap_write) begin
   if(cap_bank) edge1[video_addr]<=cap_value;
   else edge0[video_addr]<=cap_value;
  end
  q_edge0<=edge0[proc_addr];q_edge1<=edge1[proc_addr];
  q_vis0<=vis0[addr0];q_vis1<=vis1[addr1];
  if(vis_write) begin
   if(proc_vis_bank) vis1[vis_write_addr]<=vis_write_value;
   else vis0[vis_write_addr]<=vis_write_value;
  end
  if(head<N) q_head<=queue[head[AW-1:0]];
  if(state==INIT && init_border) queue[tail[AW-1:0]]<={init_y,init_x};
  else if(enqueue) queue[tail[AW-1:0]]<={ny,nx};
  if(I_tvalid) begin
   if(yy[2:0]==0 && !xx[0]) row_acc[bx]<=edge_hit;
   else row_acc[bx]<=cap_value;
  end
 end
 always @(posedge I_clk or negedge I_rst_n) begin
  if(!I_rst_n) begin
   x<=0;y<=0;cap_bank<=0;display_bank<=1;result_valid<=0;
   cap_complete<=0;busy<=0;ready<=0;ready_bank<=0;
   proc_edge_bank<=0;proc_vis_bank<=0;head<=0;tail<=0;
   proc_addr<=0;init_addr<=0;init_x<=0;init_y<=0;
   cur_x<=0;cur_y<=0;dir<=0;state<=IDLE;
  end else begin
   if(I_tvalid) begin
    if(I_tlast || xx==IMG_WIDTH/4-1) begin
     x<=0;y<=yy==IMG_HEIGHT-1 ? 0:yy+1'b1;
     if(yy==IMG_HEIGHT-1) cap_complete<=1;
    end else begin x<=xx+1'b1;y<=yy;end
   end
   case(state)
    INIT: begin
     if(init_border) tail<=tail+1'b1;
     if(init_addr==N-1) state<=POP;
     else begin
      init_addr<=init_addr+1'b1;
      if(init_x==COLS-1) begin init_x<=0;init_y<=init_y+1'b1;end
      else init_x<=init_x+1'b1;
     end
    end
    POP: begin
     if(head==tail) begin busy<=0;ready<=1;ready_bank<=proc_vis_bank;state<=IDLE;end
     else state<=POP_GET;
    end
    POP_GET: begin
     {cur_y,cur_x}<=q_head;head<=head+1'b1;dir<=0;state<=REQ;
    end
    REQ: begin
     if(neighbor_valid) begin proc_addr<=ny*COLS+nx;state<=WAIT_RAM;end
     else if(dir==3) state<=POP;
     else dir<=dir+1'b1;
    end
    WAIT_RAM: state<=TEST;
    TEST: begin
     if(enqueue) tail<=tail+1'b1;
     if(dir==3) state<=POP;
     else begin dir<=dir+1'b1;state<=REQ;end
    end
   endcase
   if(sof && ready) begin display_bank<=ready_bank;result_valid<=1;ready<=0;end
   if(start_job) begin
    proc_edge_bank<=cap_bank;cap_bank<=~cap_bank;
    proc_vis_bank<=~next_display;
    busy<=1;head<=0;tail<=0;init_addr<=0;init_x<=0;init_y<=0;
    state<=INIT;cap_complete<=0;
   end
  end
 end
 reg border_d;
 always @(posedge I_clk or negedge I_rst_n) begin
  if(!I_rst_n) begin O_tvalid<=0;O_tlast<=0;O_tuser<=0;border_d<=1;end
  else begin
   O_tvalid<=I_tvalid;O_tlast<=I_tvalid&&I_tlast;O_tuser<=I_tvalid&&I_tuser;
   border_d<=bx==0||bx==COLS-1||by==0||by==ROWS-1;
  end
 end
 wire filled=result_valid && !border_d && !(display_bank ? q_vis1:q_vis0);
 assign O_tdata=filled ? {96{1'b1}}:96'd0;
 assign O_tready=I_tready;
endmodule
