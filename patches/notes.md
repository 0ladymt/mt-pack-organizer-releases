MT Pack Organizer 0.9.22

Correções:
- corrige CS0016 "arquivo está sendo usado por outro processo" ao preparar o gerador YMT;
- cada execução agora compila o bridge YMT em uma pasta temporária exclusiva, sem disputar a mesma DLL com outra instância;
- corrige o selo de versão da interface, que estava sendo preenchido antes de AppVersion existir;
- texto do gerador agora descreve corretamente: 1 resource e até 150 peças por categoria em cada DLC;
- mantém a estrutura stream/[female|male]/categoria e a divisão _01, _02... antes do ^;
- mantém geração sem ZIP automático para maior velocidade;
- mantém logo oficial limpa e testes de YMT/layout no pipeline.
