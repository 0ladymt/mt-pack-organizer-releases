MT Pack Organizer 0.9.21

Correções principais:
- o limite de 150 agora é POR CATEGORIA em cada DLC, não 150 peças no resource inteiro;
- gera UM ÚNICO resource/pasta geral;
- estrutura final: stream/[female|male]/categoria;
- os DLCs são diferenciados pelo sufixo _01, _02, _03... antes do ^ nos nomes dos YDD/YTD;
- cada categoria reinicia em 000 dentro de cada DLC;
- removidas as várias pastas de add-on separadas;
- removida a criação automática de vários ZIPs, eliminando a etapa mais lenta do build;
- cópia de YDD/YTD feita por IO direto;
- logo oficial limpa da MT Studio substitui a imagem corrompida;
- versão exibida na interface acompanha a versão real;
- pipeline agora testa também a estrutura de resource único e impede regressão para ZIP/pastas separadas;
- fallback netstandard/.NET Framework e validação YMT permanecem ativos.
