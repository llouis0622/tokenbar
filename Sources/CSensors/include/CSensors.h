#ifndef CSENSORS_H
#define CSENSORS_H

typedef struct {
    double actual;
    double minimum;
    double maximum;
    double target;
    int mode;
} tb_fan_info;

void tb_read_temperatures(double *cpu, double *gpu);

int tb_fan_count(void);
int tb_fan_read(int index, tb_fan_info *info);
int tb_fan_set_manual(int index, double rpm);
int tb_fan_set_auto(int index);

#endif
