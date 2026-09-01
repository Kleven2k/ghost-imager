`timescale 1ns/1ps
`default_nettype none

// i2c_master: fast-mode I2C (400 kHz SCL) master transport.
//
// Drives a slave-addressed, sub-addressed read/write transaction:
// START -> slave address+R/W -> sub-address (8 or 16-bit) -> data byte(s)
// -> STOP. Byte count and sub-address width are given per-transaction by
// the caller; the caller must know how many bytes it wants transferred.
//
// SCL/SDA are open-drain: this module never drives a line high. Each line
// is split into oe/out/in so the tristate assign lives in the top-level
// wrapper next to the physical pin, not inside this module:
//   assign sda = sda_oe ? sda_out : 1'bz;
// sda_out and scl_out are always driven 1'b0 by this module (pulling low
// is the only active drive an I2C device performs); *_oe low means
// "released", letting the bus pull-up take the line high.
//
// CLK_HZ is the input clk frequency; SCL_HZ the target bus rate (fast-mode
// I2C caps at 400 kHz). Not multi-master aware: no bus-busy/arbitration
// detection is implemented.
module i2c_master #(
    parameter int CLK_HZ = 100_000_000,
    parameter int SCL_HZ = 400_000,
    // Timing constants, in clk_i2c_cntr counts (i.e. clk cycles within one
    // clk_i2c half-period). Defaults meet I2C fast-mode timing at the
    // default CLK_HZ/SCL_HZ. All four must stay well under DIV_100MHZ
    // (= CLK_HZ/(SCL_HZ*2)); a sim-speed wrapper overriding CLK_HZ/SCL_HZ
    // downward must scale these proportionally or they'll never be reached.
    parameter logic [7:0] START_IND_SETUP = 70,  // Time before negedge of scl
    parameter logic [7:0] START_IND_HOLD  = 60,  // Time after posedge of clock when start occurs (not used)
    parameter logic [7:0] DATA_SETUP_TIME = 2,   // Time needed before posedge of scl
    parameter logic [7:0] DATA_HOLD_TIME  = 3,   // Time after negedge that scl is held
    parameter logic [7:0] STOP_IND_SETUP  = 60   // Time after posedge of scl before stop occurs
)(
    input  wire logic clk,
    input  wire logic rst_n,

    // Transaction request
    input  wire logic [7:0]  i_addr_w_rw,  // 7-bit slave address + R/W in LSB (0=write, 1=read)
    input  wire logic [15:0] i_sub_addr,   // sub-address to send (width selected by i_sub_len)
    input  wire logic        i_sub_len,    // 0 = 8-bit sub-address, 1 = 16-bit sub-address
    input  wire logic [23:0] i_byte_len,   // number of data bytes to read or write
    input  wire logic        req_trans,    // pulse: start a new transaction
    input  wire logic [7:0]  i_data_write, // next write byte; caller must hold stable until req_data_chunk pulses again

    // Read data
    output logic [7:0] data_out,
    output logic       valid_out,

    // I2C lines (open-drain; see header note)
    output logic       scl_oe,
    output logic       scl_out,
    input  wire logic  scl_in,
    output logic       sda_oe,
    output logic       sda_out,
    input  wire logic  sda_in,

    // Host-facing status
    output logic       req_data_chunk,  // pulse: request next write byte on i_data_write
    output logic       busy,
    output logic       nack
);

    typedef enum logic [3:0] {
        IDLE,
        START,
        RESTART,
        SLAVE_ADDR,
        SUB_ADDR,
        READ,
        WRITE,
        GRAB_DATA,
        ACK_NACK_RX,
        ACK_NACK_TX,
        STOP,
        RELEASE_BUS
    } state_t;

    state_t state, next_state;

    // sda is never actively driven high, only pulled low, so sda_out is
    // tied low permanently; scl_out actually carries clk_i2c (see bottom
    // of file) since this module always drives SCL while active.
    assign sda_out = 1'b0;
    assign sda_oe  = sda_oe_reg;
    // scl_oe/scl_out: driven near the bottom of the file, next to clk_i2c.

    // Half-period of clk_i2c in clk cycles: clk_i2c toggles every DIV_100MHZ
    // cycles, so a full SCL period is 2*DIV_100MHZ clk cycles.
    
    localparam int DIV_100MHZ = CLK_HZ / (SCL_HZ * 2);

    // Internal registers
    logic        sda_oe_reg;   // drives sda_oe: 1 = actively pulling SDA low, 0 = released
    logic [7:0]  addr;
    logic        rw;
    logic [15:0] sub_addr;
    logic        sub_len;
    logic [23:0] byte_len;
    logic        en_scl;
    logic        byte_sent;
    logic [23:0] num_byte_sent;
    logic [2:0]  cntr;
    logic [7:0]  byte_sr;
    logic        read_sub_addr_sent_flag;
    logic [7:0]  data_to_write;
    logic [7:0]  data_in_sr;

    // For generation of 400KHz clock
    logic clk_i2c;
    logic [15:0] clk_i2c_cntr;

    // For taking a sample of the scl and sca
    logic [1:0]  sda_curr;      // So this one is asynchronous especially with replies from the slave, must have synchronization chain of 2
    logic        sda_prev;
    logic scl_prev, scl_curr;   // master will always drive this line, so it doesen't matter

    logic ack_in_prog;      // For sending acks during read
    logic ack_nack;
    logic en_end_indicator;

    logic grab_next_data;
    logic scl_is_high;
    logic scl_is_low;

    // clk_i2c 400KHz is synchronous to clk, so no need for 2 reg synchronization chain in other blocks
    // Note: For other input clks (125MHz) use fractional clock divider
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            clk_i2c_cntr <= 16'd0;
            clk_i2c      <= 1'b1;
        end
        else if (!en_scl) begin
            clk_i2c_cntr <= 16'd0;
            clk_i2c      <= 1'b1;
        end
        else begin
            clk_i2c_cntr <= clk_i2c_cntr + 16'd1;
            if (clk_i2c_cntr == DIV_100MHZ-1) begin
                clk_i2c <= !clk_i2c;
                clk_i2c_cntr <= 16'd0;
            end
        end
    end

    // FSM
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            data_out                 <= 8'd0;
            valid_out                <= 1'b0;
            req_data_chunk           <= 1'b0;
            busy                     <= 1'b0;
            nack                     <= 1'b0;
            addr                     <= 8'd0;
            rw                       <= 1'b0;
            sub_addr                 <= 16'd0;
            sub_len                  <= 1'b0;
            byte_len                 <= 24'd0;
            en_scl                   <= 1'b0;
            byte_sent                <= 1'b0;
            num_byte_sent            <= 24'd0;
            cntr                     <= 3'd0;
            byte_sr                  <= 8'd0;
            read_sub_addr_sent_flag  <= 1'b0;
            data_to_write            <= 8'd0;
            data_in_sr               <= 8'd0;
            ack_nack                 <= 1'b0;
            ack_in_prog              <= 1'b0;
            en_end_indicator         <= 1'b0;
            scl_is_high              <= 1'b0;
            scl_is_low               <= 1'b0;
            grab_next_data           <= 1'b0;
            sda_oe_reg <= 1'b0;
            state <= IDLE;
            next_state <= IDLE;
        end 
        else begin
            valid_out <= 1'b0;
            req_data_chunk <= 1'b0;
            
            case (state)
                /***
                 * State: IDLE
                 * Purpose: Monitor the master of this module's readiness to begin a new transaction
                 * How it works: clock generation of 400KHz clock is directly tied to beginging the enable line.
                 *               The 400KHz clock's cycle begins at high, 125 100MHz clock cycles pass before it is driven low,
                                 therefore next state will seek to drive sda line low, signaling a start bit.
                 */
                IDLE: begin 
                    if (req_trans & !busy) begin
                        // set busy
                        busy <= 1'b1;
                        // set FSM in motion
                        state <= START;
                        next_state <= SLAVE_ADDR;

                        // Set all master inputs to local registers to modify and or reference later
                        addr <= i_addr_w_rw;
                        rw <= i_addr_w_rw[0];
                        // sub_addr[15:8] is always shifted out first (see SLAVE_ADDR).
                        // 8-bit mode has only one byte to send, so it must be
                        // pre-shifted into the upper half here.
                        sub_addr <= i_sub_len ? i_sub_addr : {i_sub_addr[7:0], 8'b0};
                        sub_len <= i_sub_len;
                        data_to_write <= i_data_write;
                        byte_len <= i_byte_len;

                        // begin the 400kHz generation; SDA stays released
                        // (bus idles high) until START actively pulls it low
                        en_scl <= 1'b1;
                        sda_oe_reg <= 1'b0;

                        // Reset flags and or counters
                        nack <= 1'b0;
                        read_sub_addr_sent_flag <= 1'b0;
                        num_byte_sent <= 24'd0;
                        byte_sent <= 1'b0;
                    end 
                end

                /***
                 * State: START
                 * Purpose: Enable the start signal and move to next appropriate address
                 * How it works: Since this will only be utilized when starting a write or read,
                 *               we now that if read_sub_addr_sent_flag is high, then we are performing a
                 *               read, and that information would have been sent in the input addr, Else,
                 *               even if it was a write, it does not matter.
                 */
                START: begin
                    if (scl_prev & scl_curr & clk_i2c_cntr == START_IND_SETUP) begin    // check that scl is high, and that a necessary wait time is held
                        sda_oe_reg <= 1'b1;                                         // pull SDA low: START condition, and toggle for the clock to begin
                        byte_sr <= {addr[7:1], 1'b0};                               // Don't need to check read or write, will always have write in a read request as well
                        state <= SLAVE_ADDR;
                        $display("DUT: I2C MASTER | TIMESTAMTP: %t | MESSAGE: START INDICATION!", $time);
                    end
                end

                /***
                 * State: RESTART
                 * Purpose: To toggle a repeat start
                 * How it works: Must await the negedge of clk, and drive the line high.
                 */
                RESTART: begin
                    if (!scl_curr & scl_prev) begin
                        sda_oe_reg <= 1'b0;             // Release SDA, line goes high
                    end

                    if (!scl_prev & scl_curr) begin     // so i2c cntr has reset
                        scl_is_high <= 1'b1;
                    end

                    if (scl_is_high) begin
                        if (clk_i2c_cntr == START_IND_SETUP) begin  // Must wait minimum setup time
                            scl_is_high <= 1'b0;
                            sda_oe_reg <= 1'b1;         // Pull SDA low: repeated START
                            state <= SLAVE_ADDR;
                            byte_sr <= addr;
                        end
                    end
                end

                /***
                 * State: SLAVE_ADDR
                 * Purpose: Write slave addr and based on state of system, move to sub_addr or read
                 * How it works: We know that this state will go the either read or to writing the sub addr.
                 *               If we reach this state again, the flag will be set, and we know we are performing
                 *               a read. The setup time is inconsequential, simply need to account for hold time
                 */
                SLAVE_ADDR: begin
                    // When scl has fallen, we can change sda
                    if (byte_sent & cntr[0]) begin
                        byte_sent <= 1'b0;                      // deassert the flag
                        next_state <= read_sub_addr_sent_flag ? READ : SUB_ADDR;    // Check to see if sub addr was sent, we only reach this state again if doing a read
                        byte_sr <= sub_addr[15:8];              // regardless of sub addr length, higher byte will be sent first
                        state <= ACK_NACK_RX;                   // await for nack_ack
                        sda_oe_reg <= 1'b0;                     // release sda line so slave can drive ACK
                        cntr <= 3'd0;
                        $display("DUT: I2C MASTER | TIMESTAMT: %t | MESSAGE: SLAVE_ADDR SENT!", $time);
                    end
                    else begin
                        if (!scl_curr & scl_prev) begin
                            scl_is_low <= 1'b1;
                        end

                        if (scl_is_low) begin
                            if (clk_i2c_cntr == DATA_HOLD_TIME) begin
                                {byte_sent, cntr} <= {byte_sent, cntr} + 1;     // incr cntr, with overflow being caught (due to overflow, no need to set cntr to 0)
                                sda_oe_reg <= !byte_sr[7];              // send MSB: bit=1 -> release, bit=0 -> pull low
                                byte_sr <= {byte_sr[6:0], 1'b0};        // shift out MSB
                                scl_is_low <= 1'b0;
                            end
                        end
                    end
                end

                /***
                * State: Sub_addr
                * Purpose: to grab a sub address
                * How it Works: Send out the MSB of the sub_addr. If it is 16 bit sub_addr, toggle the flag,
                *               and then send MSB after receiving ACK. Once this state has finished sending
                *               sub addr, set the associated flag high, so other states may move to appropriate
                *               states.
                */
                SUB_ADDR: begin
                    if(byte_sent & cntr[0]) begin
                        if(sub_len) begin                       //1 for 16 bit
                            state <= ACK_NACK_RX;
                            next_state <= SUB_ADDR;
                            sub_len <= 1'b0;                    //denote only want 8 bit next time
                            byte_sr <= sub_addr[7:0];           //set the byte shift register
                            $display("DUT: I2C MASTER | TIMESTAMP: %t | MESSAGE: MSB OF SUB ADDR SENT", $time);
                        end
                        else begin
                            next_state <= rw ? RESTART : WRITE;   //move to appropriate state
                            byte_sr <= rw ? byte_sr : data_to_write; //if write, want to setup the data to write to device
                            read_sub_addr_sent_flag <= 1'b1;    //For dictating state of machine
                            $display("DUT: I2C MASTER | TIMESTAMP: %t | MESSAGE: SUB ADDR SENT", $time);
                        end
                        
                        cntr <= 3'd0;
                        byte_sent <= 1'b0;                      //deassert the flag
                        state <= ACK_NACK_RX;                   //await for nack_ack
                        sda_oe_reg <= 1'b0;                      //release sda line so slave can drive ACK
                    end
                    else begin
                        if(!scl_curr & scl_prev) begin
                            scl_is_low <= 1'b1;
                        end

                        if(scl_is_low) begin
                            if(clk_i2c_cntr == DATA_HOLD_TIME) begin
                                scl_is_low <= 1'b0;
                                {byte_sent, cntr} <= {byte_sent, cntr} + 1;       //incr cntr, with overflow being caught
                                sda_oe_reg <= !byte_sr[7];              //send MSB: bit=1 -> release, bit=0 -> pull low
                                byte_sr <= {byte_sr[6:0], 1'b0};        //shift out MSB
                            end
                        end
                    end
                end
                
                /***
                * State: Reads
                * Purpose: Read 1 byte messages that are set on posedge of i2c_clk
                * How it Works: Need to read all 8 bits, on posedge of clock. SDA will be
                *               stable high before this occurs, thus it's fine to grab sda_prev,
                *               which is synchronous to clk. Every
                */
                READ: begin
                    if(byte_sent) begin
                        byte_sent <= 1'b0;          //reset flag
                        data_out  <= data_in_sr;    //put information in valid output
                        valid_out <= 1'b1;          //Let master know valid output
                        state <= ACK_NACK_TX;       //Send ack
                        next_state <= (num_byte_sent == byte_len-1) ? STOP : READ;      //Have we read all bytes?
                        ack_nack <= num_byte_sent == byte_len-1;                        //If true, then 1, which is a nack
                        num_byte_sent <= num_byte_sent + 24'd1;  //Incr number of bytes read
                        ack_in_prog <= 1'b1;
                        $display("DUT: I2C MASTER | TIMESTAMP: %t | MESSAGE: READ BYTE #%d SENT!", $time, num_byte_sent);
                    end
                    else begin
                        if(!scl_prev & scl_curr) begin
                            scl_is_high <= 1'b1;
                        end
                        
                        if(scl_is_high) begin
                            if(clk_i2c_cntr == START_IND_SETUP) begin
                                valid_out <= 1'b0;
                                {byte_sent, cntr} <= cntr + 1;
                                data_in_sr <= {data_in_sr[6:0], sda_prev}; //MSB first
                                scl_is_high <= 1'b0;
                            end
                        end
                    end
                end
                
                /***
                * State: Write
                * Purpose: Write specified data words starting from address and incrementing by 1
                * How it Works: Simply send data out 1 byte at a time, with corresponding acks form slave.
                *               When all bytes are written, quit comms.
                */
                WRITE: begin
                    if(byte_sent & cntr[0]) begin
                        cntr <= 3'd0;
                        byte_sent <= 1'b0;
                        state <= ACK_NACK_RX;
                        sda_oe_reg <= 1'b0;                     //release sda line so slave can drive ACK
                        next_state <= (num_byte_sent == byte_len-1) ? STOP : GRAB_DATA;
                        num_byte_sent <= num_byte_sent + 1'b1;
                        grab_next_data <= 1'b1;
                        $display("DUT: I2C MASTER | TIMESTAMP: %t | MESSAGE: WRITE BYTE #%d SENT!", $time, num_byte_sent);
                    end
                    else begin
                        if(!scl_curr & scl_prev) begin
                            scl_is_low <= 1'b1;
                        end

                        if(scl_is_low) begin //negedge
                            if(clk_i2c_cntr == DATA_HOLD_TIME) begin
                                {byte_sent, cntr} <= {byte_sent, cntr} + 1;
                                sda_oe_reg <= !byte_sr[7];              //bit=1 -> release, bit=0 -> pull low
                                byte_sr <= {byte_sr[6:0], 1'b0};        //shift out MSB
                                scl_is_low <= 1'b0;
                            end
                        end
                    end
                end
                
                /***
                * State: GRAB_DATA
                * Purpose: Grab next 8 bit segment as needed
                * How it works: dequeue data, then grab the word requested (dequeue is req_data_chunk)
                */
                GRAB_DATA: begin
                    if(grab_next_data) begin
                        req_data_chunk <= 1'b1;
                        grab_next_data <= 1'b0;
                    end
                    else begin
                        state <= WRITE;
                        byte_sr <= i_data_write;
                    end
                end
                
                /***
                * State: ACK_NACK_RX
                * Purpose: Receive ack_nack from slave
                * How it works: sda is already freed, simply look at posedges of scl, and look at data
                *               remember low is considered an ack, and high is a nack
                */
                ACK_NACK_RX: begin
                    if(!scl_prev & scl_curr) begin
                        scl_is_high <= 1'b1;
                    end
                    
                    if(scl_is_high) begin
                        if(clk_i2c_cntr == START_IND_SETUP) begin
                            if(!sda_prev) begin      //checking for the ack condition (its low)
                                state <= next_state;
                                $display("DUT: I2C MASTER | TIMESTAMP: %t | MESSAGE: rx ack encountered", $time);
                            end
                            else begin
                                $display("DUT: I2C MASTER | TIMESTAMP: %t | MESSAGE: rx nack encountered", $time);
                                nack <= 1'b1;
                                busy <= 1'b0;
                                sda_oe_reg <= 1'b0;             //release sda line
                                en_scl <= 1'b0;
                                state <= IDLE;
                            end
                            scl_is_high <= 1'b0;
                        end
                    end
                end

                /***
                * State: ACK_NACK_TX
                * Purpose: Take hold of SDA to acknowledge the read
                * How it works: On first negedge, since previous state will move on posedge,
                *               pull the line low for an ack. On second negedge, release sda.
                */
                ACK_NACK_TX: begin
                    if(!scl_curr & scl_prev) begin
                        scl_is_low <= 1'b1;
                    end
                    if(scl_is_low) begin          //negedge
                        if(clk_i2c_cntr == DATA_HOLD_TIME) begin
                            if(ack_in_prog) begin
                                sda_oe_reg <= !ack_nack;        //ack_nack=0 (ACK) -> pull low, =1 (NACK) -> release
                                ack_in_prog <= 1'b0;
                            end
                            else begin
                                sda_oe_reg <= next_state == STOP ? 1'b1 : 1'b0;
                                en_end_indicator <= next_state == STOP ? 1'b1 : en_end_indicator;
                                state <= next_state;
                            end
                            scl_is_low <= 1'b0;
                        end
                    end
                end
                
                /***
                * State: STOP
                * Purpose: Pulls bus low on negedge, and waits for scl to be high
                *          drive sda to high from low, which is stop indication
                */
                STOP: begin
                    if(!scl_curr & scl_prev & !rw) begin //negedge only if we are writing
                        sda_oe_reg <= 1'b1;              //pull sda low
                        en_end_indicator <= 1'b1;
                    end

                    //Note addition of counter, needed to ensure that there is enough delay for target device
                    if(scl_curr & scl_prev & en_end_indicator) begin
                        scl_is_high <= 1'b1;
                        en_end_indicator <= 1'b0;
                    end

                    if(scl_is_high) begin
                        if(clk_i2c_cntr == STOP_IND_SETUP) begin
                            sda_oe_reg <= 1'b0;          //release sda: low-to-high while scl high = STOP
                            state <= RELEASE_BUS;
                            scl_is_high <= 1'b0;
                        end
                    end
                end

                /***
                * State: Release bus
                * Purpose: Release the bus
                * How it works: Turn off 400KHz out and release the sda line, go back to idle
                */
                RELEASE_BUS: begin
                    if(clk_i2c_cntr == DIV_100MHZ-3) begin
                        en_scl <= 1'b0;
                        state <= IDLE;
                        sda_oe_reg <= 1'b0;              //release sda line
                        busy <= 1'b0;
                    end
                end
                
                default:
                    state <= IDLE;
            endcase
        end
    end

    /*
    * Purpose: grabbing sda from slave
    */
    always_ff @(negedge clk) begin
        if (!rst_n) begin
            {sda_curr, sda_prev} <= '0;
            {scl_curr, scl_prev} <= '0;
        end
        else begin
            sda_curr <= {sda_curr[0], sda_in};  //2 flip flop synchronization chain
            sda_prev <= sda_curr[1];
            scl_curr <= clk_i2c;
            scl_prev <= scl_curr;
        end
    end

    // scl is always actively driven while a transaction is in progress
    // (no clock-stretching support); sda's drive-enable comes from the FSM.
    assign scl_oe = en_scl;
    assign scl_out = clk_i2c;

    endmodule
