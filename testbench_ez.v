// This is free and unencumbered software released into the public domain.
//
// Anyone is free to copy, modify, publish, use, compile, sell, or
// distribute this software, either in source code form or as a compiled
// binary, for any purpose, commercial or non-commercial, and by any
// means.

`timescale 1 ns / 1 ps

module testbench;
    reg clk = 1;
    reg resetn = 0;
    wire trap;

    // Geração do Clock: Período de 10ns (100 MHz)
    always #5 clk = ~clk;

    // Gerenciamento do Reset do Sistema
    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("testbench.vcd");
            $dumpvars(0, testbench);
        end
        
        // Mantém o reset ativo no início para estabilizar o hardware
        resetn <= 0;
        repeat (10) @(posedge clk);
        resetn <= 1;
        
        // Tempo limite de simulação para evitar loops infinitos
        repeat (2000) @(posedge clk);
        $finish;
    end

    // Sinais do Barramento de Memória Nativo do PicoRV32
    wire mem_valid;
    wire mem_instr;
    reg mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0] mem_wstrb;
    reg  [31:0] mem_rdata;

    // Fios de Interconexão do Barramento do Coprocessador (PCPI)
    wire         pcpi_valid;
    wire [31:0]  pcpi_insn;
    wire [31:0]  pcpi_rs1;
    wire [31:0]  pcpi_rs2;
    wire         pcpi_wr;
    wire [31:0]  pcpi_rd;
    wire         pcpi_wait;
    wire         pcpi_ready;

    // ====================================================================
    // MONITOR DE LOGS DO TERMINAL
    // ====================================================================
    always @(posedge clk) begin
        // Monitor de busca e acesso à memória comum
        if (mem_valid && mem_ready) begin
            if (mem_instr)
                $display("ifetch 0x%08x: 0x%08x", mem_addr, mem_rdata);
            else if (mem_wstrb)
                $display("write  0x%08x: 0x%08x (wstrb=%b)", mem_addr, mem_wdata, mem_wstrb);
            else
                $display("read   0x%08x: 0x%08x", mem_addr, mem_rdata);
        end

        // Monitor do Coprocessador Criptográfico: Captura instruções de leitura (funct3 = 011)
        if (pcpi_valid && pcpi_ready && (pcpi_insn[6:0] == 7'b0001011) && (pcpi_insn[14:12] == 3'b011)) begin
            $display(">>> COPROCESSADOR PCPI: INSTRUÇÃO GIFT-128 DETECTADA (Leitura Quadrante %d) <<<", pcpi_insn[21:20]);
            $display("    Dado retornado para o registrador x%0d da CPU: 0x%08x", pcpi_insn[11:7], pcpi_rd);
        end
    end

    // Instanciação da CPU PicoRV32
    picorv32 #(
        .ENABLE_PCPI(1'b1),        // Mantém ativado o coprocessador
        .CATCH_ILLINSN(1'b0),      // <-- CRÍTICO: Desliga o bloqueio de instruções customizadas!
        .CATCH_MISALIGN(1'b0),     // Desliga travas de desalinhamento para o teste rápido
        .BARREL_SHIFTER(1'b1),
        .COMPRESSED_ISA(1'b0)
    ) uut (
        .clk         (clk        ),
        .resetn      (resetn     ),
        .trap        (trap       ),
        .mem_valid   (mem_valid  ),
        .mem_instr   (mem_instr  ),
        .mem_ready   (mem_ready  ),
        .mem_addr    (mem_addr   ),
        .mem_wdata   (mem_wdata  ),
        .mem_wstrb   (mem_wstrb  ),
        .mem_rdata   (mem_rdata  ),
        
        // Conexões PCPI de Hardware
        .pcpi_valid  (pcpi_valid ),
        .pcpi_insn   (pcpi_insn  ),
        .pcpi_rs1    (pcpi_rs1   ),
        .pcpi_rs2    (pcpi_rs2   ),
        .pcpi_wr     (pcpi_wr    ),
        .pcpi_rd     (pcpi_rd    ),
        .pcpi_wait   (pcpi_wait  ),
        .pcpi_ready  (pcpi_ready )
    );

    // Instanciação Externa do Acelerador GIFT-128 acoplado ao PCPI
    gift128_accelerator gift_coproc (
        .clk         (clk),
        .rstn        (resetn),
        .pcpi_valid  (pcpi_valid),
        .pcpi_insn   (pcpi_insn),
        .pcpi_rs1    (pcpi_rs1),
        .pcpi_rs2    (pcpi_rs2),
        .pcpi_wr     (pcpi_wr),
        .pcpi_rd     (pcpi_rd),
        .pcpi_wait   (pcpi_wait),
        .pcpi_ready  (pcpi_ready),
        .wdata       (pcpi_rs1) // Conecta no pcpi_rs1 padrão
    );

    // Memória Ram Fictícia da Simulação (Alinhada em palavras de 32 bits)
    reg [31:0] memory [0:255];
    integer i;

    // Inicialização do Firmware de Teste na Memória
    initial begin
        // Zera o array de memória para evitar lixo de simulação
        for (i = 0; i < 256; i = i + 1)
            memory[i] = 32'h 00000000;

        // ====================================================================
        // PROGRAMA EM ASSEMBLY EMULADO (VETOR DE TESTE DA ISA ESTENDIDA)
        // ====================================================================
        
       // ====================================================================
        // NOVO PROGRAMA: ALIMENTANDO O HARDWARE COM OS DADOS DO BASELINE
        // ====================================================================
        
        // Carrega x10 (RS1) com a parte alta do Texto Plano: 0xfedcba98
        memory[0] = 32'h fedcb537; // lui  x10, 0xfedcb
        memory[1] = 32'h a9850513; // addi x10, x10, 0xa98

        // Carrega x11 (RS2) com a parte baixa do Texto Plano: 0x76543210
        memory[2] = 32'h 76543537; // lui  x11, 0x76543
        memory[3] = 32'h 21058513; // addi x11, x11, 0x210

        // Instruções CUSTOM_0 de Carga: Despacha os registradores para o Coprocessador
        memory[4] = 32'h 0005100b; // gift_load Q0, x10 -> Buffer[31:0]   = x10
        memory[5] = 32'h 0015100b; // gift_load Q1, x11 -> Buffer[63:32]  = x11
        memory[6] = 32'h 0005900b; // gift_load Q2, x10 -> Buffer[95:64]  = x10
        memory[7] = 32'h 0015900b; // gift_load Q3, x11 -> Buffer[127:96] = x11

        // Instrução CUSTOM_0 de Execução Criptográfica (1 Ciclo Combinacional)
        memory[8] = 32'h 0000200b; // gift_exec        -> Processa 1 rodada completa

        // Instruções CUSTOM_0 de Leitura: Devolve o resultado para x12
        memory[9]  = 32'h 0000360b; // gift_read x12, Q0
        memory[10] = 32'h 0010360b; // gift_read x12, Q1
        memory[11] = 32'h 0020360b; // gift_read x12, Q2
        memory[12] = 32'h 0030360b; // gift_read x12, Q3

        // Encerramento
        memory[13] = 32'h 00100073; // ebreak
    end

    // Interface de Leitura Síncrona da Memória RAM
    always @(posedge clk) begin
        mem_ready <= 0;
        if (mem_valid && !mem_ready) begin
            // Restringe o endereçamento ao tamanho do nosso array
            if (mem_addr < 1024) begin
                mem_ready <= 1;
                mem_rdata <= memory[mem_addr >> 2];
            end
        end
    end

endmodule