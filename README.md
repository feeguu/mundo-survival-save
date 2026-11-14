# Mundo compartilhado

Qualquer pessoa do grupo pode hospedar o mundo. O Git guarda a versão oficial e um
**cadeado** (`host.lock`) garante que só uma pessoa hospeda por vez.

## Como jogar

1. Abra o **Radmin VPN** e entre na rede do grupo.
2. Veja se alguém já está hospedando:
   - **Sim** → entre no Minecraft pelo IP Radmin dessa pessoa (aparece na tela dela).
   - **Não** → dê dois cliques em **`hospedar.bat`**. Se outra pessoa estiver hospedando,
     o script avisa e não abre o servidor.
3. Para fechar: digite `stop` ou aperte **Ctrl+C**. **Não feche a janela no X.**
   Espere aparecer "Mundo enviado e cadeado liberado".

Enquanto o servidor está aberto, o mundo é salvo e enviado a cada 10 minutos.

## Primeira vez (cada amigo)

1. Instale o [Git](https://git-scm.com/download/win) e o Java 25 (Temurin ou Oracle).
2. Peça para ser adicionado como colaborador do repositório no GitHub.
3. Num terminal, na pasta onde quer guardar o mundo:
   ```
   git clone https://github.com/USUARIO/REPO.git servermine
   ```
   Na primeira vez que o Git falar com o GitHub, ele abre uma janela de login.
4. Rode o `hospedar.bat`. Ele pergunta seu nome e baixa o `server.jar` sozinho.

## E se...

| Situação | O que acontece |
|---|---|
| Duas pessoas abrem ao mesmo tempo | Só uma consegue pegar o cadeado; a outra recebe um aviso. |
| O PC do host desligou ou travou | Quando o host abrir de novo, o script envia os saves que ficaram pendentes. Para só enviar, sem hospedar: `hospedar.bat -ApenasSincronizar` |
| O host sumiu e o cadeado ficou preso | Depois de 30 min sem sinal, o script oferece quebrar o cadeado. O que foi jogado depois do último save do host se perde. |
| Alguém quebrou seu cadeado enquanto você hospedava | Aparece um aviso em vermelho. Pare o servidor; seu mundo vai para `backups-locais\` e nada é sobrescrito. |
| Forçar a quebra do cadeado sem esperar | `hospedar.bat -ForcarCadeado` (combine com o grupo antes) |

## Ajustes

- Intervalo de save: `hospedar.bat -IntervaloSaveMin 5`
- Memória: `hospedar.bat -MemoriaMax 6G`
- Atualizar o Minecraft: mude `$VersaoMinecraft` no topo do `hospedar.ps1`, faça commit e push.
  Todo mundo baixa o novo `server.jar` automaticamente.
- Para mandar um comando ao servidor de fora da janela, escreva uma linha no arquivo
  `.comandos.txt` dentro da pasta.

## Manutenção: o histórico cresce

Cada save gera um commit com os arquivos de região que mudaram. Quando o repositório
passar de ~1 GB, apague o histórico antigo. Faça isso **sem ninguém hospedando**:

```
git checkout --orphan novo
git add -A
git commit -m "Historico compactado"
git branch -D main
git branch -m main
git push --force origin main
```

Depois disso, cada amigo apaga a pasta e clona de novo. Se quiser manter as versões antigas,
baixe antes um zip do repositório pelo GitHub.
