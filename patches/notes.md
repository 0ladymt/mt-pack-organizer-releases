MT Pack Organizer 0.9.18

Correção:
- corrige o erro "Não encontrei a facade netstandard.dll" em PCs sem o Developer/Targeting Pack do .NET Framework;
- o gerador baixa automaticamente a facade oficial netstandard 2.0 quando ela não existe no Windows;
- o teste de publicação força esse mesmo caminho de fallback para impedir uma release que funcione apenas no computador do GitHub;
- geração YMT, branding oficial e seta roxa permanecem preservados.
