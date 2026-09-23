# Vários scripts para facilitar o trabalho com mosaicos de ortos

## resample_mosaic.ps1
O problema de converter um vrt para tif com resolução mais grosseira é um processo muito lento. o gdal_translate é muito lento, e pouco paralelizável. Mesmo com um CPU de muitos núcleos, ocupa apenas 1 núcleo. Quanto maior o mosaico mais a lentidão aumenta de forma mais que linear.
A solução: converter em pedaços e em paralelo. E tentar otimizar ao máximo, eliminando processamento dispensável.
Este script faz isto:
1) corta o mosaico em pedaços, e processa cada pedaço numa thread. a aceleração aqui é tanto maior quanto o número de processos solicitado até ao limite do cpu e da storage.
2) corta o mosaico calculando limites que respeitem a resolução solicitada e o tamanho dos blocos, evitando ler o mesmo bloco em 2 tiles diferentes ou lidar com meios-pixeis.
3) usa o nível de overviews mais perto da resolução pedida. por ex., num mosaico de 0.25m/pixel, ao pedirmos uma resolução de 4m/pixel, o script vai usar -oo overview_level=3.
4) não faz resample a não ser que a resolução pedida não exista num nível das overviews (convém sempre evitar resample, embora o impacto no desempenho seja menor).

Dentro do script há um texto de ajuda com mais detalhes técnicos das razões que levam a maior desempenho e da mecânica interna do gdal.
