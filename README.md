# tachyon-cli-scripts
Various Particle.IO tachyon scripts and tricks

## tachyon-info-dump.sh

This was built with the help of The Chatmeister. I would probably ask for their help to make changes. It dumps a whole bunch of information about a Tachyon device into indivisual files or sends it back over STDIN. It also includes some performance benchmarks ; by default it doesn't do disk benchmarks to avoid wear. 

So a quick way to do things would be:

```
curl -O https://raw.githubusercontent.com/martooy/tachyon-cli-scripts/main/tachyon-info-dump.sh
chmod +x tachyon-info-dump.sh
./tachyon-info-dump.sh
```

## Bash Aliases
Coming soon. The goal is to remove a bunch of the unique commands from the Tachyon and provide a unified but somewhat minimal CLI interface. Probably through single script that can be symlinked and self-identifies based on it's name and does the needful. Keeps all the code in one file but provides clean short commands. 



