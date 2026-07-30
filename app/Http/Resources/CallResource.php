<?php

namespace App\Http\Resources;

use App\Helpers\DateHelper;
use Illuminate\Http\Resources\Json\JsonResource;

/**
 * @mixin \App\Models\Call
 */
class CallResource extends JsonResource
{
    /**
     * Transform the resource into an array.
     *
     * @param  \Illuminate\Http\Request  $request
     */
    public function toArray($request): array
    {
        return [
            'id' => $this->id,
            'called_at' => DateHelper::getTimestamp($this->called_at),
            'duration' => $this->duration,
            'type' => $this->type,
            'answered' => $this->answered,
            'who_initiated' => $this->who_initiated,
            'description' => $this->description,
            'created_at' => DateHelper::getTimestamp($this->created_at),
            'updated_at' => DateHelper::getTimestamp($this->updated_at),
        ];
    }
}
