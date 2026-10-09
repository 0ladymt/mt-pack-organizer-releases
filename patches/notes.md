MT Pack Organizer 0.9.20

Correções principais:
- o limite de 150 agora é POR CATEGORIA em cada DLC, não 150 peças no resource inteiro;
- gera UM ÚNICO resource/pasta geral;
- estrutura: stream/[female|male]/categoria;
- os DLCs são diferenciados somente pelo sufixo _01, _02, _03... antes do ^ nos nomes;
- cada categoria reinicia a numeração em 000 dentro de cada DLC;
- removidas as várias pastas de add-on separadas;
- removida a criação automática de vários ZIPs, que era a principal causa da demora;
- cópia de YDD/YTD usa IO direto para acelerar a geração;
- logo oficial limpa da MT Studio substitui a imagem bugada;
- versão mostrada na interface agora acompanha a versão real do aplicativo;
- fallback netstandard/.NET Framework e validação YMT permanecem ativos.
